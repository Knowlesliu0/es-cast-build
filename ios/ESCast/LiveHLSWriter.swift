import AVFoundation
import UniformTypeIdentifiers

/// append/isReadyFor run on the capture queue. Retains two startup buffers,
/// then one source image for sparse screen updates; never queues a frame backlog.
final class LiveHLSWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let store: HLSStore
    private let queue: DispatchQueue
    private let failureLock = NSLock()
    private var failure: Error?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var firstVideo: CMSampleBuffer?
    private var firstAudio: CMSampleBuffer?
    private var origin: CMTime?
    private var offset = CMTime.zero
    private let lead = CMTime(seconds: 10, preferredTimescale: 600)
    private var lastVideo: CMTime?
    private var lastSourceImage: CMSampleBuffer?
    private var lastSourceVideoPTS: CMTime?
    private var videoGridOrigin: CMTime?
    private var lastVideoSlot: Int64?
    private var lastAudio: CMTime?
    private var accepting = true
    private var completed = false
    private var monitor: DispatchSourceTimer?
    private var monitoringStarted: DispatchTime?
    private var lastVideoArrival: DispatchTime?
    private var lastAudioArrival: DispatchTime?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var videoCount = 0
    private var audioCount = 0
    private var pacedFrames = 0
    private var heldFrames = 0
    var onFailure: ((Error) -> Void)?
    var onSummary: ((String) -> Void)?

    init(store: HLSStore, queue: DispatchQueue) {
        self.store = store; self.queue = queue
        super.init()
    }

    private func currentFailure() -> Error? {
        failureLock.lock(); defer { failureLock.unlock() }; return failure
    }
    private func fail(_ error: Error) {
        failureLock.lock()
        let first = failure == nil
        if first { failure = error }
        failureLock.unlock()
        if first {
            store.invalidate()
            queue.async { [weak self] in self?.cancelMonitoring() }
            onFailure?(error)
        }
    }
    private func error(_ message: String, code: Int = 10) -> NSError {
        NSError(domain: "ESCast.HLS", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func sourceTimeout(trigger: String, incomingPTS: CMTime? = nil,
                               incomingType: AVMediaType? = nil) -> NSError {
        let now = DispatchTime.now().uptimeNanoseconds
        func age(_ time: DispatchTime?) -> Any {
            guard let time else { return NSNull() }
            return Double(now - time.uptimeNanoseconds) / 1_000_000_000
        }
        func seconds(_ time: CMTime?) -> Any {
            guard let time, time.isNumeric else { return NSNull() }
            return CMTimeGetSeconds(time)
        }
        return NSError(domain: "ESCast.HLS", code: 12, userInfo: [
            NSLocalizedDescriptionKey: "部分影音來源已超過兩秒未更新",
            "timeout_trigger": trigger,
            "source_failure_uptime_seconds": ProcessInfo.processInfo.systemUptime,
            "video_arrival_age": age(lastVideoArrival), "audio_arrival_age": age(lastAudioArrival),
            "last_video_pts": seconds(lastVideo), "last_audio_pts": seconds(lastAudio),
            "incoming_pts": seconds(incomingPTS), "incoming_type": incomingType?.rawValue ?? "none"
        ])
    }

    /// Start when capture starts, including the case where no sample ever arrives.
    /// This and append run on the same capture queue; arrivals before start are retained.
    func startMonitoring() {
        guard monitoringStarted == nil, accepting, currentFailure() == nil else { return }
        monitoringStarted = .now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.checkSourceArrival() }
        monitor = timer
        timer.resume()
    }

    private func cancelMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    private func checkSourceArrival() {
        guard accepting, currentFailure() == nil, let monitoringStarted else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        func secondsSince(_ time: DispatchTime) -> Double {
            Double(now - time.uptimeNanoseconds) / 1_000_000_000
        }
        if writer == nil {
            if secondsSince(monitoringStarted) >= 3 {
                fail(error("啟動後沒有收到完整影音來源", code: 11))
            }
        } else if let audio = lastAudioArrival, secondsSince(audio) >= 2 {
            // ScreenCaptureKit can stop sending images while the screen is static.
            // Audio drives held images; missing audio still terminates this A/V stream.
            fail(sourceTimeout(trigger: "arrival_watchdog"))
        }
    }

    func isReadyFor(_ type: AVMediaType) -> Bool {
        if currentFailure() != nil { return true } // append reports the original failure.
        guard writer != nil else { return true }
        return (type == .video ? videoInput : audioInput)?.isReadyForMoreMediaData ?? false
    }

    func append(_ sample: CMSampleBuffer, type: AVMediaType) throws {
        do {
            guard accepting else { throw HLSError.closed }
            if let failure = currentFailure() { throw failure }
            guard sample.isValid, CMSampleBufferDataIsReady(sample),
                  CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else {
                throw error("影音來源時間不正確")
            }
            if type == .video {
                lastVideoArrival = .now()
                lastSourceVideoPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            }
            if type == .audio { lastAudioArrival = .now() }
            if writer == nil {
                if type == .video, firstVideo == nil { firstVideo = sample }
                if type == .audio, firstAudio == nil { firstAudio = sample }
                guard let video = firstVideo, let audio = firstAudio else { return }
                try configure(video: video, audio: audio)
                firstVideo = nil; firstAudio = nil
                try write(video, type: .video)
                try write(audio, type: .audio)
                return
            }
            if type == .audio {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if let previous = lastAudio, CMTimeCompare(pts, previous) <= 0 {
                    throw error("音訊時間倒退或重複", code: 13)
                }
                try holdImage(until: pts)
            }
            try write(sample, type: type)
        } catch {
            fail(error)
            throw error
        }
    }

    private func configure(video: CMSampleBuffer, audio: CMSampleBuffer) throws {
        guard let image = CMSampleBufferGetImageBuffer(video) else { throw error("影像來源沒有畫面") }
        let firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(video)
        let firstAudioPTS = CMSampleBufferGetPresentationTimeStamp(audio)
        let start = CMTimeCompare(firstVideoPTS, firstAudioPTS) <= 0 ? firstVideoPTS : firstAudioPTS
        origin = start
        offset = CMTimeSubtract(lead, start)
        let assetWriter = AVAssetWriter(contentType: UTType.mpeg4Movie)
        assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        assetWriter.initialSegmentStartTime = lead
        assetWriter.delegate = self
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidth(image), AVVideoHeightKey: CVPixelBufferGetHeight(image),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalDurationKey: 2, AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel]]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings,
                                   sourceFormatHint: CMSampleBufferGetFormatDescription(video))
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000],
            sourceFormatHint: CMSampleBufferGetFormatDescription(audio))
        vi.expectsMediaDataInRealTime = true; ai.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(vi), assetWriter.canAdd(ai) else { throw error("裝置不支援所選影音編碼") }
        assetWriter.add(vi); assetWriter.add(ai)
        writer = assetWriter; videoInput = vi; audioInput = ai
        guard assetWriter.startWriting() else { throw assetWriter.error ?? error("無法啟動影音編碼") }
        assetWriter.startSession(atSourceTime: .zero)
    }

    /// Audio progress supplies a 30 Hz hold, leaving one frame for capture jitter.
    /// Source images keep their original PTS. Held images never update source arrivals.
    private func holdImage(until audioPTS: CMTime) throws {
        guard let source = lastSourceImage, var previous = lastVideo else { return }
        let heldFrameRate: Int32 = 30
        let maximumCatchUpSeconds = 2
        let maximumFrames = maximumCatchUpSeconds * Int(heldFrameRate)
        let interval = CMTime(value: 1, timescale: heldFrameRate)
        let limit = CMTimeSubtract(audioPTS, interval)
        var count = 0
        while CMTimeCompare(CMTimeAdd(previous, interval), limit) <= 0 {
            guard count < maximumFrames else {
                throw sourceTimeout(trigger: "audio_timeline_jump", incomingPTS: audioPTS, incomingType: .audio)
            }
            let next = CMTimeAdd(previous, interval)
            var timing = CMSampleTimingInfo(duration: interval, presentationTimeStamp: next,
                                            decodeTimeStamp: .invalid)
            var held: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: source, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &held)
            guard status == noErr, let held else { throw error("無法維持靜態畫面") }
            try write(held, type: .video, isHeld: true)
            previous = next
            count += 1
        }
    }

    private func write(_ sample: CMSampleBuffer, type: AVMediaType, isHeld: Bool = false) throws {
        guard let writer, writer.status == .writing else { throw self.writer?.error ?? error("影音編碼已中止") }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Screen updates may be sparse while audio advances. Their most recent
        // sample timestamps are not an A/V synchronization measurement. Preserve
        // each source timestamp and let the arrival watchdog detect a stalled source.
        // An incoming video frame still requires a recent audio timeline.
        if type == .video, let other = lastAudio,
           CMTimeGetSeconds(CMTimeSubtract(pts, other)) > 2 {
            throw sourceTimeout(trigger: "cross_track_pts", incomingPTS: pts, incomingType: type)
        }
        var videoSlot: Int64?
        if type == .video {
            if !isHeld {
                guard CMSampleBufferGetImageBuffer(sample) != nil else { throw error("影像來源沒有畫面") }
                if lastSourceImage == nil || CMTimeCompare(pts,
                    CMSampleBufferGetPresentationTimeStamp(lastSourceImage!)) > 0 {
                    // Keep the newest source even if pacing omits its encoded frame.
                    lastSourceImage = sample
                }
            }
            let elapsed = CMTimeSubtract(pts, videoGridOrigin ?? pts)
            // Move slot boundaries by half a 60Hz source period to tolerate capture jitter.
            // Select at most one frame per 30Hz slot; preserve the source PTS unchanged.
            let position = CMTimeAdd(elapsed, CMTime(value: 1, timescale: 120))
            let slot = CMTimeConvertScale(position, timescale: 30, method: .roundTowardZero).value
            if let previous = lastVideoSlot, slot <= previous { pacedFrames += 1; return }
            videoSlot = slot
        }
        if type == .audio, let previous = lastAudio, CMTimeCompare(pts, previous) <= 0 {
            throw error("音訊時間倒退或重複", code: 13)
        }
        let input = type == .video ? videoInput : audioInput
        let selectedReady = input?.isReadyForMoreMediaData
        guard let input, selectedReady == true else {
            let now = DispatchTime.now().uptimeNanoseconds
            func age(_ arrival: DispatchTime?) -> Any {
                guard let arrival else { return NSNull() }
                return Double(now - arrival.uptimeNanoseconds) / 1_000_000_000
            }
            let seconds = CMTimeGetSeconds(pts)
            let videoReady = type == .video ? selectedReady : videoInput?.isReadyForMoreMediaData
            let audioReady = type == .audio ? selectedReady : audioInput?.isReadyForMoreMediaData
            throw NSError(domain: "ESCast.HLS", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "即時編碼無法及時接收影音",
                "backpressure_input": type == .video ? (isHeld ? "held_video" : "source_video") : "audio",
                "backpressure_pts_seconds": seconds.isFinite ? seconds : NSNull(),
                "backpressure_video_ready": videoReady.map { $0 as Any } ?? NSNull(),
                "backpressure_audio_ready": audioReady.map { $0 as Any } ?? NSNull(),
                "backpressure_video_arrival_age_seconds": age(lastVideoArrival),
                "backpressure_audio_arrival_age_seconds": age(lastAudioArrival),
                "backpressure_uptime_seconds": ProcessInfo.processInfo.systemUptime
            ])
        }
        let shifted = try retime(sample)
        guard input.append(shifted) else { throw writer.error ?? error("無法寫入影音樣本") }
        if type == .video {
            lastVideo = pts; videoCount += 1
            if isHeld { heldFrames += 1 }
            if videoGridOrigin == nil { videoGridOrigin = pts }
            lastVideoSlot = videoSlot
        }
        else { lastAudio = pts; audioCount += 1 }
    }

    private func retime(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                                    entriesNeededOut: &count) == noErr,
              count > 0, count <= 4096 else { throw error("無法讀取影音時間") }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid,
                              presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        let read = timing.withUnsafeMutableBufferPointer {
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: $0.baseAddress,
                                                  entriesNeededOut: nil)
        }
        guard read == noErr else { throw error("無法讀取影音時間") }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric {
                timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, offset)
            }
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset)
            }
        }
        var result: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer {
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress!, sampleBufferOut: &result)
        }
        guard status == noErr, let result else { throw error("無法調整共同影音時間") }
        return result
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        do {
            guard !segmentData.isEmpty else { throw HLSError.invalidFragment }
            let data = segmentData.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
            if segmentType == .initialization { try store.setInitialization(data) }
            else {
                guard let reports = segmentReport?.trackReports, !reports.isEmpty else { throw HLSError.invalidFragment }
                let duration = reports.map { CMTimeGetSeconds($0.duration) }.max() ?? 0
                try store.append(data, duration: duration)
            }
            if currentFailure() == nil {
                onSummary?(store.ready ? "串流已備妥；可由 rPlay TV 讀取" : "正在準備串流分段（\(store.producedSegmentCount)）…")
            }
        } catch {
            let original = error as NSError
            var info = original.userInfo
            info["hls_segment_bytes"] = segmentData.count
            info["hls_segment_is_initialization"] = segmentType == .initialization
            info["hls_track_durations"] = segmentReport?.trackReports.map {
                CMTimeGetSeconds($0.duration)
            } ?? []
            fail(NSError(domain: original.domain, code: original.code, userInfo: info))
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.completed {
                    if let error = self.currentFailure() { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                    return
                }
                guard self.finishContinuation == nil else { continuation.resume(throwing: HLSError.closed); return }
                self.accepting = false
                self.cancelMonitoring()
                self.firstVideo = nil; self.firstAudio = nil
                self.lastSourceImage = nil
                self.finishContinuation = continuation
                guard let writer = self.writer else { self.completeFinish(self.currentFailure()); return }
                self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        self.completeFinish(writer.status == .completed ? nil : writer.error ?? HLSError.closed)
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 20) {
                    guard self.finishContinuation != nil else { return }
                    writer.cancelWriting()
                    self.completeFinish(self.error("串流編碼未能完成保存", code: 15))
                }
            }
        }
    }

    private func completeFinish(_ error: Error?) {
        guard let continuation = finishContinuation else { return }
        if let error { fail(error) }
        store.finish()
        finishContinuation = nil; completed = true
        if let failure = currentFailure() { continuation.resume(throwing: failure) }
        else { continuation.resume() }
    }

    func diagnostic() -> [String: Any] {
        queue.sync {
            var result: [String: Any] = ["video_samples": videoCount, "audio_samples": audioCount,
                "paced_video_frames": pacedFrames, "produced_segments": store.producedSegmentCount,
                "held_video_frames": heldFrames,
                "encoded_source_video_frames": videoCount - heldFrames,
                "retained_source_images": lastSourceImage == nil ? 0 : 1,
                "retained_segments": store.retainedSegmentCount, "completed": completed,
                "vehicle_av_sync_verified": false]
            if let origin { result["shared_origin_seconds"] = CMTimeGetSeconds(origin) }
            if let lastSourceVideoPTS { result["last_source_video_pts"] = CMTimeGetSeconds(lastSourceVideoPTS) }
            if let lastVideoArrival {
                let age = Double(DispatchTime.now().uptimeNanoseconds - lastVideoArrival.uptimeNanoseconds) / 1_000_000_000
                result["source_video_arrival_age"] = age
                result["source_video_state"] = age >= 2 ? "no_recent_source_image" : "receiving"
            }
            if let error = currentFailure() {
                let native = error as NSError
                result["error_domain"] = native.domain; result["error_code"] = native.code
                result["error_message"] = native.localizedDescription
                if native.domain == "ESCast.HLS", native.code == 14 {
                    for key in ["backpressure_input", "backpressure_pts_seconds", "backpressure_video_ready",
                                "backpressure_audio_ready", "backpressure_video_arrival_age_seconds",
                                "backpressure_audio_arrival_age_seconds", "backpressure_uptime_seconds"] {
                        if let value = native.userInfo[key] { result[key] = value }
                    }
                }
            }
            return result
        }
    }
}
