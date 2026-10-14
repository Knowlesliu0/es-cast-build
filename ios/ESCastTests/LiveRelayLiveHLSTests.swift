import AVFoundation
import CoreVideo
import XCTest
@testable import ESCastTestHost

/// Real-time synthetic production and the actual relay consumer overlap. No screen or receiver is tested.
final class LiveRelayLiveHLSTests: XCTestCase {
    @MainActor
    func testRelayConsumesGrowingHLSBeforeWriterFinishesAndPersistsDecodedSamples() async throws {
        let sourceURL = try XCTUnwrap(Bundle.main.url(forResource: "ESCast-Car-Test-60s",
            withExtension: "mp4", subdirectory: "CarTestAssets"))
        let sourceDuration = CMTimeGetSeconds(try await AVURLAsset(url: sourceURL).load(.duration))
        let deadlineSeconds = 35.0
        guard sourceDuration > deadlineSeconds + 10 else {
            throw LiveRelayIntegrationFailure(message: "The real-time source must outlast the entire live observation deadline")
        }
        let store = HLSStore()
        let queue = DispatchQueue(label: "tw.escast.live-relay-integration.capture", qos: .userInitiated)
        let writer = LiveHLSWriter(store: store, queue: queue)
        let server = LocalHLSServer(store: store)
        let relay = LiveRelayModel()
        let captureID = UUID()
        let progress = LiveRelayProducerProgress()
        var producer: Task<Void, Never>?
        var failure: Error?
        var observed = LiveRelayDecodedContinuity()
        var processedRows = 0
        var criteriaReached = false
        var matchedElapsed: Double?
        var writerBeforeFinish: [String: Any] = [:]
        var httpBeforeStop: [String: Any] = [:]
        var sourceWasProducing = false
        let logFolder = URL.documentsDirectory.appending(path: "LiveRelayDiagnostics")
        let priorLogs = Set((try? FileManager.default.contentsOfDirectory(at: logFolder,
            includingPropertiesForKeys: nil)) ?? [])

        writer.onSummary = { [weak relay, weak writer] _ in
            Task { @MainActor in
                guard let relay, let writer, relay.armed else { return }
                if store.ready, progress.snapshot().segmentsAtConsumerStart == nil {
                    let diagnostic = writer.diagnostic()
                    progress.update {
                        $0.segmentsAtConsumerStart = store.producedSegmentCount
                        $0.sourceVideoPTSAtConsumerStart = diagnostic["last_source_video_pts"] as? Double
                        $0.sharedOriginAtConsumerStart = diagnostic["shared_origin_seconds"] as? Double
                    }
                }
                relay.updateCapture(active: true, ready: store.ready, sessionID: captureID, pickerBusy: false)
            }
        }
        writer.onFailure = { [weak relay] error in
            let native = error as NSError
            let message = "\(native.domain) (\(native.code)): \(native.localizedDescription)"
            Task { @MainActor in
                progress.update { $0.writerFailure = message }
                relay?.updateCapture(active: true, ready: false, sessionID: captureID, pickerBusy: false)
            }
        }
        server.onFailure = { error in
            let native = error as NSError
            let message = "\(native.domain) (\(native.code)): \(native.localizedDescription)"
            Task { @MainActor in progress.update { $0.serverFailure = message } }
        }

        do {
            guard relay.prepare() else { throw LiveRelayIntegrationFailure(message: relay.status) }
            let newLogs = try FileManager.default.contentsOfDirectory(at: logFolder,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" && !priorLogs.contains($0) }
            guard newLogs.count == 1, let activeLogURL = newLogs.first else {
                throw LiveRelayIntegrationFailure(message: "Exactly one new private relay diagnostic is required")
            }
            relay.updateCapture(active: true, ready: false, sessionID: captureID, pickerBusy: false)
            try await server.start()
            let began = ProcessInfo.processInfo.systemUptime
            producer = Task.detached(priority: .userInitiated) {
                progress.update { $0.running = true }
                defer { progress.update { $0.running = false } }
                do {
                    try await Self.feedRealTime(sourceURL, into: writer, queue: queue, progress: progress)
                    progress.update { $0.completed = true }
                } catch is CancellationError {
                    // The observation deliberately ends before the 60-second source does.
                } catch {
                    progress.update { $0.sourceFailure = String(describing: error) }
                }
            }

            while ProcessInfo.processInfo.systemUptime - began < deadlineSeconds {
                let source = progress.snapshot()
                if let message = source.sourceFailure ?? source.writerFailure ?? source.serverFailure {
                    throw LiveRelayIntegrationFailure(message: message)
                }
                guard relay.armed else { throw LiveRelayIntegrationFailure(message: relay.status) }
                guard !source.completed else {
                    throw LiveRelayIntegrationFailure(message: "Source completed before the live consumer observation")
                }
                // Read only completed lines from this test's private active file. Production UI
                // still exposes its export URL only after closing the diagnostic.
                let currentRows = try Self.readRows(activeLogURL)
                guard currentRows.count >= processedRows else {
                    throw LiveRelayIntegrationFailure(message: "Active diagnostic was truncated")
                }
                for row in currentRows.dropFirst(processedRows) { try observed.observe(row) }
                processedRows = currentRows.count
                let newSegments = store.producedSegmentCount - (source.segmentsAtConsumerStart ?? store.producedSegmentCount)
                let normalizedSourceLimit = source.normalizedSourceVideoLimit
                let decodedNewSource = normalizedSourceLimit.map { (observed.lastDecodedItemTime ?? -1) >= $0 + 2 } ?? false
                let matched = ProcessInfo.processInfo.systemUptime - began
                if matched < deadlineSeconds, observed.clockProgress >= 8,
                   observed.playingWallTime >= 10, newSegments >= 4, decodedNewSource {
                    criteriaReached = true
                    matchedElapsed = matched
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            guard criteriaReached else {
                throw LiveRelayIntegrationFailure(message: "Live observation deadline: clock progress=\(observed.clockProgress), decoded playing wall=\(observed.playingWallTime), segments=\(store.producedSegmentCount); \(relay.status)")
            }

            writerBeforeFinish = writer.diagnostic()
            httpBeforeStop = server.diagnostic()
            let sourceAtAssessment = progress.snapshot()
            sourceWasProducing = sourceAtAssessment.running && !sourceAtAssessment.completed
            let liveManifest = store.response(for: HLSRequest(method: "GET", path: "/live.m3u8", range: nil))
            XCTAssertEqual(liveManifest.status, 200)
            XCTAssertFalse(String(decoding: liveManifest.body, as: UTF8.self).contains("#EXT-X-ENDLIST"))
            XCTAssertEqual(writerBeforeFinish["completed"] as? Bool, false)
            XCTAssertNil(writerBeforeFinish["error_domain"], "Production writer failure must remain visible")
            XCTAssertNil(sourceAtAssessment.sourceFailure)
            XCTAssertNil(sourceAtAssessment.writerFailure)
            XCTAssertNil(sourceAtAssessment.serverFailure)
            XCTAssertFalse(sourceAtAssessment.producerObservedMainThread)
            XCTAssertTrue(sourceWasProducing, "The producer must still be sending samples when playback is assessed")
            XCTAssertLessThan(sourceAtAssessment.lastSourcePTS ?? sourceDuration, sourceDuration - 1)
            XCTAssertGreaterThanOrEqual(observed.clockProgress, 8,
                "Anchor playback only after a new decoded frame and ready-and-playing sample")
            XCTAssertGreaterThanOrEqual(store.producedSegmentCount - (sourceAtAssessment.segmentsAtConsumerStart ?? store.producedSegmentCount), 4)
            XCTAssertGreaterThanOrEqual(httpBeforeStop["media_requests"] as? Int ?? 0, 4)
            XCTAssertGreaterThanOrEqual(httpBeforeStop["playlist_requests"] as? Int ?? 0, 2)
            XCTAssertEqual(httpBeforeStop["binding"] as? String, "127.0.0.1:8766")
            XCTAssertTrue(relay.player.isMuted)
            XCTAssertFalse(relay.player.isExternalPlaybackActive)
            relay.stop(reason: "user")
            let closedURL = try XCTUnwrap(relay.logURL)
            relay.updateCapture(active: true, ready: true, sessionID: captureID, pickerBusy: false)
            XCTAssertFalse(relay.armed)
            XCTAssertFalse(relay.active)
            XCTAssertNil(relay.player.currentItem)
            XCTAssertEqual(relay.logURL, closedURL)
        } catch {
            failure = error
            writerBeforeFinish = writer.diagnostic()
            httpBeforeStop = server.diagnostic()
            let source = progress.snapshot()
            sourceWasProducing = source.running && !source.completed
            relay.stop(reason: "test_cleanup")
        }

        // Close the model first, then cancel and await the source before draining the writer.
        // No test-only listener or producer may survive to occupy fixed port 8766 in the next case.
        relay.stop(reason: "test_cleanup")
        producer?.cancel()
        if let producer { await producer.value }
        do { try await writer.finish() }
        catch { failure = failure ?? error }
        writer.onSummary = nil; writer.onFailure = nil
        server.stop()
        server.onFailure = nil

        if let logURL = relay.logURL {
            let rows = try Self.readRows(logURL)
            var confirmed = LiveRelayDecodedContinuity()
            do { for row in rows { try confirmed.observe(row) } }
            catch { failure = failure ?? error }
            let source = progress.snapshot()
            let diagnosticClockProgress = confirmed.clockProgress
            let summary: [String: Any] = [
                "scope": "Real-time synthetic source -> production growing HLS -> actual LiveRelayModel/AVPlayer; no physical receiver",
                "source_mode": "real_time_synthetic", "source_duration_seconds": sourceDuration,
                "relay_session_uuid": rows.first?["relay_session_uuid"] ?? "",
                "capture_session_uuid": captureID.uuidString,
                "segments_at_consumer_start": source.segmentsAtConsumerStart ?? -1,
                "source_video_pts_at_consumer_start": source.sourceVideoPTSAtConsumerStart.map { $0 as Any } ?? NSNull(),
                "source_shared_origin_at_consumer_start": source.sharedOriginAtConsumerStart.map { $0 as Any } ?? NSNull(),
                "normalized_source_limit_at_consumer_start": source.normalizedSourceVideoLimit.map { $0 as Any } ?? NSNull(),
                "segments_before_writer_finish": writerBeforeFinish["produced_segments"] ?? -1,
                "writer_completed_before_stop": writerBeforeFinish["completed"] ?? true,
                "source_producing_before_stop": sourceWasProducing,
                "source_video_buffers": source.videoBuffers, "source_audio_buffers": source.audioBuffers,
                "producer_observed_main_thread": source.producerObservedMainThread,
                "source_timing": source.timings.mapValues { $0.diagnostic },
                "first_ready_playing_clock": confirmed.firstPlayingClock.map { $0 as Any } ?? NSNull(),
                "last_ready_playing_clock": confirmed.lastPlayingClock.map { $0 as Any } ?? NSNull(),
                "last_new_decoded_item_time": confirmed.lastDecodedItemTime.map { $0 as Any } ?? NSNull(),
                "criteria_matched_before_deadline": criteriaReached,
                "criteria_matched_elapsed_seconds": matchedElapsed.map { $0 as Any } ?? NSNull(),
                "decoded_sample_rows": confirmed.newDecodedSamples,
                "decoded_sample_clock_progress_seconds": diagnosticClockProgress,
                "decoded_pixel_observations": rows.last?["decoded_pixel_observations"] ?? 0,
                "terminal_reason": rows.last?["reason"] ?? "",
                "http": httpBeforeStop,
                "source_failure": source.sourceFailure ?? "", "writer_failure": source.writerFailure ?? "",
                "server_failure": source.serverFailure ?? "", "test_failure": failure.map { String(describing: $0) } ?? "",
                "vehicle_playback_verified": false, "vehicle_av_sync_verified": false, "audible_output_verified": false
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print("Live relay growing-HLS evidence: \(String(decoding: data, as: UTF8.self))")
            if failure == nil {
                XCTAssertEqual(rows.last?["event"] as? String, "stop")
                XCTAssertEqual(rows.last?["reason"] as? String, "user")
                XCTAssertGreaterThanOrEqual(confirmed.newDecodedSamples, 6)
                XCTAssertGreaterThanOrEqual(diagnosticClockProgress, 5,
                    "The production 1 Hz log must contain at least five seconds of clock progress with actual decoded pixels")
                XCTAssertGreaterThanOrEqual(rows.last?["decoded_pixel_observations"] as? Int ?? 0, 6)
                let sourceLimit = try XCTUnwrap(source.normalizedSourceVideoLimit)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(confirmed.lastDecodedItemTime), sourceLimit + 2,
                    "Decode imagery beyond every source frame that existed when the consumer started")
                for row in rows {
                    XCTAssertEqual(row["consumer_muted"] as? Bool, true)
                    XCTAssertEqual(row["external_playback_active"] as? Bool, false)
                    XCTAssertEqual(row["vehicle_playback_verified"] as? Bool, false)
                    XCTAssertEqual(row["vehicle_av_sync_verified"] as? Bool, false)
                    XCTAssertEqual(row["audible_output_verified"] as? Bool, false)
                    XCTAssertEqual(row["feedback_exclusion_verified"] as? Bool, false)
                    if row["consumer_requested"] as? Bool == true {
                        XCTAssertEqual(row["bound_capture_session_uuid"] as? String, captureID.uuidString)
                        XCTAssertEqual(row["source_active"] as? Bool, true)
                        XCTAssertEqual(row["source_ready"] as? Bool, true)
                    }
                }
            }
        } else if failure == nil {
            throw LiveRelayIntegrationFailure(message: "The closed production relay log is required")
        }
        if let failure { throw failure }
    }

    private static func readRows(_ url: URL) throws -> [[String: Any]] {
        let log = try String(contentsOf: url, encoding: .utf8)
        return try log.split(separator: "\n").map {
            guard let row = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw LiveRelayIntegrationFailure(message: "Relay diagnostic must contain JSON objects")
            }
            return row
        }
    }

    nonisolated private static func feedRealTime(_ url: URL, into writer: LiveHLSWriter, queue: DispatchQueue,
                                                 progress: LiveRelayProducerProgress) async throws {
        progress.update { $0.producerObservedMainThread = $0.producerObservedMainThread || Thread.isMainThread }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
            throw LiveRelayIntegrationFailure(message: "The real-time fixture needs both media tracks")
        }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        let audio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        video.alwaysCopiesSampleData = false; audio.alwaysCopiesSampleData = false
        guard reader.canAdd(video), reader.canAdd(audio) else {
            throw LiveRelayIntegrationFailure(message: "The reader cannot supply the production writer formats")
        }
        reader.add(video); reader.add(audio)
        let readerStart = ProcessInfo.processInfo.systemUptime
        guard reader.startReading() else {
            throw reader.error ?? LiveRelayIntegrationFailure(message: "Cannot start the real-time source reader")
        }
        progress.recordTiming("reader_start", seconds: ProcessInfo.processInfo.systemUptime - readerStart)
        defer { reader.cancelReading() }
        func copyNext(_ output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
            let began = ProcessInfo.processInfo.systemUptime
            let result = output.copyNextSampleBuffer()
            progress.recordTiming("reader_copy", seconds: ProcessInfo.processInfo.systemUptime - began)
            return result
        }
        var nextVideo = copyNext(video)
        var nextAudio = copyNext(audio)
        guard nextVideo != nil, nextAudio != nil else {
            throw LiveRelayIntegrationFailure(message: "The source did not provide its initial image and PCM")
        }
        let wallStart = ProcessInfo.processInfo.systemUptime
        var origin: Double?
        queue.sync { writer.startMonitoring() }
        while nextVideo != nil || nextAudio != nil {
            progress.update { $0.producerObservedMainThread = $0.producerObservedMainThread || Thread.isMainThread }
            try Task.checkCancellation()
            let useVideo = nextVideo != nil && (nextAudio == nil ||
                CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(nextVideo!),
                              CMSampleBufferGetPresentationTimeStamp(nextAudio!)) <= 0)
            let type: AVMediaType = useVideo ? .video : .audio
            let sample = useVideo ? nextVideo! : nextAudio!
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite else { throw LiveRelayIntegrationFailure(message: "Source PTS is not finite") }
            if origin == nil { origin = pts }
            let remaining = pts - origin! - (ProcessInfo.processInfo.systemUptime - wallStart)
            if remaining > 0 {
                progress.recordTiming("pacing_requested", seconds: remaining)
                let waited = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                progress.recordTiming("pacing_actual", seconds: ProcessInfo.processInfo.systemUptime - waited)
            }
            let readinessBegan = ProcessInfo.processInfo.systemUptime
            let readinessDeadline = ProcessInfo.processInfo.systemUptime + 1
            while !queue.sync(execute: { writer.isReadyFor(type) }) {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < readinessDeadline else {
                    throw LiveRelayIntegrationFailure(message: "The production encoder could not accept a real-time \(type.rawValue) sample")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            progress.recordTiming("readiness", seconds: ProcessInfo.processInfo.systemUptime - readinessBegan)
            let queued = ProcessInfo.processInfo.systemUptime
            var appendBegan = queued
            try queue.sync {
                appendBegan = ProcessInfo.processInfo.systemUptime
                try writer.append(sample, type: type)
            }
            let appended = ProcessInfo.processInfo.systemUptime
            progress.recordTiming("queue_wait", seconds: appendBegan - queued)
            progress.recordTiming("append", seconds: appended - appendBegan)
            progress.recordTiming("delivery_lateness", seconds: max(0, appended - wallStart - (pts - origin!)))
            progress.update {
                $0.lastSourcePTS = pts
                if useVideo { $0.videoBuffers += 1 } else { $0.audioBuffers += 1 }
            }
            if useVideo { nextVideo = copyNext(video) }
            else { nextAudio = copyNext(audio) }
            // Remain cooperative if catching up, without changing source PTS or expected cadence.
            try await Task.sleep(nanoseconds: 100_000)
        }
        guard reader.status == .completed else {
            throw reader.error ?? LiveRelayIntegrationFailure(message: "The source reader ended unexpectedly")
        }
    }
}

private final class LiveRelayProducerProgress: @unchecked Sendable {
    struct Timing: Sendable {
        var total = 0.0
        var maximum = 0.0
        var slowCalls = 0
        var diagnostic: [String: Any] {
            ["total_seconds": total, "maximum_seconds": maximum, "calls_at_least_0_2_seconds": slowCalls]
        }
    }
    struct Snapshot: Sendable {
        var running = false
        var completed = false
        var videoBuffers = 0
        var audioBuffers = 0
        var producerObservedMainThread = false
        var lastSourcePTS: Double?
        var segmentsAtConsumerStart: Int?
        var sourceVideoPTSAtConsumerStart: Double?
        var sharedOriginAtConsumerStart: Double?
        var sourceFailure: String?
        var writerFailure: String?
        var serverFailure: String?
        var timings: [String: Timing] = [:]
        var normalizedSourceVideoLimit: Double? {
            guard let sourceVideoPTSAtConsumerStart, let sharedOriginAtConsumerStart else { return nil }
            return sourceVideoPTSAtConsumerStart - sharedOriginAtConsumerStart
        }
    }
    private let lock = NSLock()
    private var state = Snapshot()
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&state)
    }
    func recordTiming(_ name: String, seconds: Double) {
        update {
            var timing = $0.timings[name] ?? Timing()
            timing.total += seconds
            timing.maximum = max(timing.maximum, seconds)
            if seconds >= 0.2 { timing.slowCalls += 1 }
            $0.timings[name] = timing
        }
    }
}

/// Every post-anchor sample must contain newly decoded media with continuous item and wall time.
private struct LiveRelayDecodedContinuity {
    private(set) var firstPlayingClock: Double?
    private(set) var lastPlayingClock: Double?
    private(set) var lastDecodedItemTime: Double?
    private(set) var newDecodedSamples = 0
    private var firstPlayingUptime: Double?
    private var lastPlayingUptime: Double?
    private var previousElapsed: Double?
    private var previousUptime: Double?
    private var previousCount = 0

    var clockProgress: Double { (lastPlayingClock ?? 0) - (firstPlayingClock ?? 0) }
    var playingWallTime: Double { (lastPlayingUptime ?? 0) - (firstPlayingUptime ?? 0) }

    mutating func observe(_ row: [String: Any]) throws {
        guard row["event"] as? String == "sample" else { return }
        guard let elapsed = row["elapsed_seconds"] as? Double, elapsed.isFinite,
              let uptime = row["uptime_seconds"] as? Double, uptime.isFinite,
              let count = row["decoded_pixel_observations"] as? Int, count >= previousCount else {
            throw LiveRelayIntegrationFailure(message: "Sample timing or decoded counter is invalid")
        }
        let elapsedDelta = previousElapsed.map { elapsed - $0 }
        let uptimeDelta = previousUptime.map { uptime - $0 }
        if let elapsedDelta, let uptimeDelta {
            guard elapsedDelta >= 0, elapsedDelta <= 3, uptimeDelta >= 0, uptimeDelta <= 3 else {
                throw LiveRelayIntegrationFailure(message: "Raw 1 Hz sample gap exceeded three seconds or regressed")
            }
        }
        if let statedGap = row["snapshot_gap_seconds"] as? Double {
            guard statedGap >= 0, statedGap <= 3 else {
                throw LiveRelayIntegrationFailure(message: "Production snapshot gap exceeded three seconds")
            }
        }
        let newDecode = count > previousCount
        let decodedTime = row["decoded_item_time_seconds"] as? Double
        if newDecode {
            guard let decodedTime, decodedTime.isFinite,
                  lastDecodedItemTime.map({ decodedTime > $0 }) ?? true else {
                throw LiveRelayIntegrationFailure(message: "New decoded count must have a strictly newer finite item time")
            }
        }
        let readyPlaying = row["consumer_requested"] as? Bool == true
            && row["item_status"] as? Int == AVPlayerItem.Status.readyToPlay.rawValue
            && row["time_control_status"] as? Int == AVPlayer.TimeControlStatus.playing.rawValue
            && (row["player_rate"] as? Double ?? 0) > 0
        if firstPlayingClock != nil {
            guard readyPlaying, newDecode, let clock = row["player_time_seconds"] as? Double,
                  clock.isFinite, let lastPlayingClock, let elapsedDelta,
                  let decodedTime, let lastDecodedItemTime else {
                throw LiveRelayIntegrationFailure(message: "Post-anchor sample must still be playing and contain new decoded pixels")
            }
            let clockDelta = clock - lastPlayingClock
            let decodedDelta = decodedTime - lastDecodedItemTime
            guard clockDelta >= 0, clockDelta <= elapsedDelta + 0.35,
                  decodedDelta > 0, decodedDelta <= elapsedDelta + 0.35 else {
                throw LiveRelayIntegrationFailure(message: "Clock/decoded item time jumped beyond elapsed time or regressed")
            }
            self.lastPlayingClock = clock
            lastPlayingUptime = uptime
            newDecodedSamples += 1
        } else if readyPlaying, newDecode,
                  let clock = row["player_time_seconds"] as? Double, clock.isFinite {
            firstPlayingClock = clock; lastPlayingClock = clock
            firstPlayingUptime = uptime; lastPlayingUptime = uptime
            newDecodedSamples = 1
        }
        if newDecode { lastDecodedItemTime = decodedTime }
        previousCount = count; previousElapsed = elapsed; previousUptime = uptime
    }
}

private struct LiveRelayIntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
