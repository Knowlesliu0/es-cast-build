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
        let queue = DispatchQueue(label: "tw.escast.live-relay-integration.capture")
        let writer = LiveHLSWriter(store: store, queue: queue)
        let server = LocalHLSServer(store: store)
        let relay = LiveRelayModel()
        let captureID = UUID()
        let progress = LiveRelayProducerProgress()
        var producer: Task<Void, Never>?
        var failure: Error?
        var firstPlayingClock: Double?
        var lastPlayingClock: Double?
        var firstPlayingUptime: Double?
        var writerBeforeFinish: [String: Any] = [:]
        var httpBeforeStop: [String: Any] = [:]
        var sourceWasProducing = false

        writer.onSummary = { [weak relay] _ in
            Task { @MainActor in
                guard let relay, relay.armed else { return }
                if store.ready, progress.segmentsAtConsumerStart == nil {
                    progress.segmentsAtConsumerStart = store.producedSegmentCount
                }
                relay.updateCapture(active: true, ready: store.ready, sessionID: captureID, pickerBusy: false)
            }
        }
        writer.onFailure = { [weak relay] error in
            let native = error as NSError
            let message = "\(native.domain) (\(native.code)): \(native.localizedDescription)"
            Task { @MainActor in
                progress.writerFailure = message
                relay?.updateCapture(active: true, ready: false, sessionID: captureID, pickerBusy: false)
            }
        }
        server.onFailure = { error in
            let native = error as NSError
            let message = "\(native.domain) (\(native.code)): \(native.localizedDescription)"
            Task { @MainActor in progress.serverFailure = message }
        }

        do {
            guard relay.prepare() else { throw LiveRelayIntegrationFailure(message: relay.status) }
            relay.updateCapture(active: true, ready: false, sessionID: captureID, pickerBusy: false)
            try await server.start()
            let began = ProcessInfo.processInfo.systemUptime
            producer = Task { @MainActor in
                progress.running = true
                defer { progress.running = false }
                do {
                    try await self.feedRealTime(sourceURL, into: writer, queue: queue, progress: progress)
                    progress.completed = true
                } catch is CancellationError {
                    // The observation deliberately ends before the 60-second source does.
                } catch {
                    progress.sourceFailure = String(describing: error)
                }
            }

            while ProcessInfo.processInfo.systemUptime - began < deadlineSeconds {
                if let message = progress.sourceFailure ?? progress.writerFailure ?? progress.serverFailure {
                    throw LiveRelayIntegrationFailure(message: message)
                }
                guard relay.armed else { throw LiveRelayIntegrationFailure(message: relay.status) }
                guard !progress.completed else {
                    throw LiveRelayIntegrationFailure(message: "Source completed before the live consumer observation")
                }
                let now = ProcessInfo.processInfo.systemUptime
                let clock = CMTimeGetSeconds(relay.player.currentTime())
                if relay.player.currentItem?.status == .readyToPlay,
                   relay.player.timeControlStatus == .playing, clock.isFinite {
                    if firstPlayingClock == nil { firstPlayingClock = clock; firstPlayingUptime = now }
                    lastPlayingClock = clock
                }
                let clockProgress = (lastPlayingClock ?? 0) - (firstPlayingClock ?? 0)
                let playingWallTime = firstPlayingUptime.map { now - $0 } ?? 0
                let newSegments = store.producedSegmentCount - (progress.segmentsAtConsumerStart ?? store.producedSegmentCount)
                if clockProgress >= 8, playingWallTime >= 10, newSegments >= 4 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let observedProgress = (lastPlayingClock ?? 0) - (firstPlayingClock ?? 0)
            let observedWallTime = firstPlayingUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            guard observedProgress >= 8, observedWallTime >= 10,
                  store.producedSegmentCount - (progress.segmentsAtConsumerStart ?? store.producedSegmentCount) >= 4 else {
                throw LiveRelayIntegrationFailure(message: "Live observation deadline: clock progress=\(observedProgress), playing wall=\(observedWallTime), segments=\(store.producedSegmentCount); \(relay.status)")
            }

            writerBeforeFinish = writer.diagnostic()
            httpBeforeStop = server.diagnostic()
            sourceWasProducing = progress.running && !progress.completed
            let liveManifest = store.response(for: HLSRequest(method: "GET", path: "/live.m3u8", range: nil))
            XCTAssertEqual(liveManifest.status, 200)
            XCTAssertFalse(String(decoding: liveManifest.body, as: UTF8.self).contains("#EXT-X-ENDLIST"))
            XCTAssertEqual(writerBeforeFinish["completed"] as? Bool, false)
            XCTAssertNil(writerBeforeFinish["error_domain"], "Production writer failure must remain visible")
            XCTAssertNil(progress.sourceFailure)
            XCTAssertNil(progress.writerFailure)
            XCTAssertNil(progress.serverFailure)
            XCTAssertTrue(sourceWasProducing, "The producer must still be sending samples when playback is assessed")
            XCTAssertLessThan(progress.lastSourcePTS ?? sourceDuration, sourceDuration - 1)
            XCTAssertGreaterThanOrEqual((lastPlayingClock ?? 0) - (firstPlayingClock ?? 0), 8,
                "Measure progress from the first ready-and-playing clock, not its initial HLS position")
            XCTAssertGreaterThanOrEqual(store.producedSegmentCount - (progress.segmentsAtConsumerStart ?? store.producedSegmentCount), 4)
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
            sourceWasProducing = progress.running && !progress.completed
            relay.stop(reason: "test_cleanup")
        }

        // Close the model first, then cancel and await the source before draining the writer.
        // No test-only listener or producer may survive to occupy fixed port 8766 in the next case.
        relay.stop(reason: "test_cleanup")
        producer?.cancel()
        if let producer { await producer.value }
        writer.onSummary = nil; writer.onFailure = nil
        do { try await writer.finish() }
        catch { failure = failure ?? error }
        server.stop()
        server.onFailure = nil

        if let logURL = relay.logURL {
            let log = try String(contentsOf: logURL, encoding: .utf8)
            let rows = try log.split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            let decodedSamples = rows.filter {
                $0["event"] as? String == "sample" && $0["consumer_requested"] as? Bool == true
                    && $0["item_status"] as? Int == AVPlayerItem.Status.readyToPlay.rawValue
                    && $0["time_control_status"] as? Int == AVPlayer.TimeControlStatus.playing.rawValue
                    && ($0["decoded_pixel_observations"] as? Int ?? 0) > 0
            }
            let decodedClocks = decodedSamples.compactMap { $0["player_time_seconds"] as? Double }
            let diagnosticClockProgress = (decodedClocks.last ?? 0) - (decodedClocks.first ?? 0)
            let summary: [String: Any] = [
                "scope": "Real-time synthetic source -> production growing HLS -> actual LiveRelayModel/AVPlayer; no physical receiver",
                "source_mode": "real_time_synthetic", "source_duration_seconds": sourceDuration,
                "relay_session_uuid": rows.first?["relay_session_uuid"] ?? "",
                "capture_session_uuid": captureID.uuidString,
                "segments_at_consumer_start": progress.segmentsAtConsumerStart ?? -1,
                "segments_before_writer_finish": writerBeforeFinish["produced_segments"] ?? -1,
                "writer_completed_before_stop": writerBeforeFinish["completed"] ?? true,
                "source_producing_before_stop": sourceWasProducing,
                "source_video_buffers": progress.videoBuffers, "source_audio_buffers": progress.audioBuffers,
                "first_ready_playing_clock": firstPlayingClock.map { $0 as Any } ?? NSNull(),
                "last_ready_playing_clock": lastPlayingClock.map { $0 as Any } ?? NSNull(),
                "decoded_sample_rows": decodedSamples.count,
                "decoded_sample_clock_progress_seconds": diagnosticClockProgress,
                "decoded_pixel_observations": rows.last?["decoded_pixel_observations"] ?? 0,
                "terminal_reason": rows.last?["reason"] ?? "",
                "http": httpBeforeStop,
                "source_failure": progress.sourceFailure ?? "", "writer_failure": progress.writerFailure ?? "",
                "server_failure": progress.serverFailure ?? "", "test_failure": failure.map { String(describing: $0) } ?? "",
                "vehicle_playback_verified": false, "vehicle_av_sync_verified": false, "audible_output_verified": false
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print("Live relay growing-HLS evidence: \(String(decoding: data, as: UTF8.self))")
            if failure == nil {
                XCTAssertEqual(rows.last?["event"] as? String, "stop")
                XCTAssertEqual(rows.last?["reason"] as? String, "user")
                XCTAssertGreaterThanOrEqual(decodedSamples.count, 6)
                XCTAssertGreaterThanOrEqual(diagnosticClockProgress, 5,
                    "The production 1 Hz log must contain at least five seconds of clock progress with actual decoded pixels")
                XCTAssertGreaterThanOrEqual(rows.last?["decoded_pixel_observations"] as? Int ?? 0, 6)
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

    @MainActor
    private func feedRealTime(_ url: URL, into writer: LiveHLSWriter, queue: DispatchQueue,
                              progress: LiveRelayProducerProgress) async throws {
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
        guard reader.startReading() else {
            throw reader.error ?? LiveRelayIntegrationFailure(message: "Cannot start the real-time source reader")
        }
        defer { reader.cancelReading() }
        var nextVideo = video.copyNextSampleBuffer()
        var nextAudio = audio.copyNextSampleBuffer()
        guard nextVideo != nil, nextAudio != nil else {
            throw LiveRelayIntegrationFailure(message: "The source did not provide its initial image and PCM")
        }
        let wallStart = ProcessInfo.processInfo.systemUptime
        var origin: Double?
        queue.sync { writer.startMonitoring() }
        while nextVideo != nil || nextAudio != nil {
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
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            let readinessDeadline = ProcessInfo.processInfo.systemUptime + 1
            while !queue.sync(execute: { writer.isReadyFor(type) }) {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < readinessDeadline else {
                    throw LiveRelayIntegrationFailure(message: "The production encoder could not accept a real-time \(type.rawValue) sample")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try queue.sync { try writer.append(sample, type: type) }
            progress.lastSourcePTS = pts
            if useVideo { progress.videoBuffers += 1; nextVideo = video.copyNextSampleBuffer() }
            else { progress.audioBuffers += 1; nextAudio = audio.copyNextSampleBuffer() }
            // Even a late producer must yield; catch-up decoding cannot monopolize the main actor
            // and hide the test deadline or the production relay's 1 Hz diagnostic timer.
            try await Task.sleep(nanoseconds: 100_000)
        }
        guard reader.status == .completed else {
            throw reader.error ?? LiveRelayIntegrationFailure(message: "The source reader ended unexpectedly")
        }
    }
}

@MainActor
private final class LiveRelayProducerProgress {
    var running = false
    var completed = false
    var videoBuffers = 0
    var audioBuffers = 0
    var lastSourcePTS: Double?
    var segmentsAtConsumerStart: Int?
    var sourceFailure: String?
    var writerFailure: String?
    var serverFailure: String?
}

private struct LiveRelayIntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
