import AVFoundation
import CoreVideo
import QuartzCore
import XCTest
@testable import ESCastTestHost

/// A media interoperability test. Notification-only PlaybackNotificationTests remain separate.
/// It does not measure an actual speaker/display or prove rPlay TV/CarPlay compatibility.
final class LiveHLSPlaybackTests: XCTestCase {
    @MainActor
    func testRawWriterHLSOverLoopbackDecodesFixturePixelsAndAdvancesPlayerClock() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "hls-native-source", withExtension: "mp4", subdirectory: "Fixtures"),
            "The test bundle must contain the generated, synthetic Fixtures/hls-native-source.mp4")
        let store = HLSStore()
        let queue = DispatchQueue(label: "tw.escast.native-playback-test.capture")
        let writer = LiveHLSWriter(store: store, queue: queue)
        do {
            try await feedFixture(fixture, into: writer, queue: queue)
            try await writer.finish() // Its production timeout also bounds encoder finalization.
        } catch {
            try? await writer.finish() // Release encoder inputs on failure.
            throw error
        }
        XCTAssertTrue(store.ready, "The real writer must produce playable finalized fragments")
        XCTAssertGreaterThanOrEqual(store.producedSegmentCount, 5)

        let server = LocalHLSServer(store: store)
        defer { server.stop() }
        try await server.start()

        // This is the original fMP4 HLS endpoint, not a file URL or FFmpeg-remuxed MP4.
        let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:8766/live.m3u8")!)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true // We inspect decoding and item time; this is not an audible-output test.
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            item.remove(output)
        }
        player.play()

        var observations = DecodedFixtureObservations()
        let deadline = CACurrentMediaTime() + 40
        while CACurrentMediaTime() < deadline {
            if item.status == .failed {
                throw FixturePlaybackFailure(message: "AVPlayer failed: \(String(describing: item.error)); HTTP: \(server.diagnostic())")
            }
            let requestedTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if requestedTime.isNumeric, output.hasNewPixelBuffer(forItemTime: requestedTime) {
                var displayTime = CMTime.invalid
                if let pixel = output.copyPixelBuffer(forItemTime: requestedTime,
                                                       itemTimeForDisplay: &displayTime) {
                    try observations.observe(pixel, displayTime: displayTime)
                }
            }
            if observations.decodedFrames > 0 {
                // Start only after a decoded image has passed the pixel checks; an initial
                // HLS position change must not count as elapsed playback time.
                observations.observeClock(player.currentTime())
            }
            // Let AVFoundation and the main run loop run between bounded samples.
            if observations.decodedFrames >= 30, observations.darkFrames >= 10,
               observations.whiteTimes.count >= 2, observations.clockProgress >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        }

        let http = server.diagnostic()
        let evidence: [String: Any] = [
            "scope": "Synthetic fixture -> production LiveHLSWriter -> production loopback HTTP -> iOS AVPlayer decoded pixels; no vehicle or physical A/V measurement",
            "source_mode": "offline_fixture",
            "arrival_watchdog_exercised": false,
            "decoded_frames": observations.decodedFrames,
            "dark_frames": observations.darkFrames,
            "white_frame_events_item_seconds": observations.whiteTimes,
            "first_item_clock_seconds": observations.firstClock ?? -1,
            "last_item_clock_seconds": observations.lastClock ?? -1,
            "clock_progress_seconds": observations.clockProgress,
            "writer": writer.diagnostic(),
            "http": http
        ]
        let evidenceData = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(string: String(decoding: evidenceData, as: UTF8.self))
        attachment.name = "Raw HLS AVPlayer decoding evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Raw HLS AVPlayer decoding evidence: \(String(decoding: evidenceData, as: UTF8.self))")

        XCTAssertGreaterThanOrEqual(observations.decodedFrames, 30,
                                    "A ready item or successful HTTP response is not decoded video")
        XCTAssertGreaterThanOrEqual(observations.darkFrames, 10,
                                    "The encoded fixture must show its known dark region between flashes")
        XCTAssertGreaterThanOrEqual(observations.whiteTimes.count, 2,
                                    "The real decoded ROI must change from dark to white at two distinct flashes")
        XCTAssertGreaterThanOrEqual(observations.clockProgress, 2,
                                    "The player's actual item clock must advance while decoded frames change")
        if observations.whiteTimes.count >= 2 {
            // Relative decoded event times work even when the six-segment VOD starts partway
            // through the source. No assumption is made about AVPlayer's time-zero mapping.
            XCTAssertEqual(observations.whiteTimes[1] - observations.whiteTimes[0], 2, accuracy: 0.2,
                           "The fixture's adjacent flashes are two seconds apart in decoded item time")
        }
        XCTAssertGreaterThan(http["playlist_requests"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(http["media_requests"] as? Int ?? 0, 0,
                             "AVPlayer must consume actual fragments through LocalHLSServer")
    }

    private func feedFixture(_ url: URL, into writer: LiveHLSWriter,
                             queue: DispatchQueue) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
            throw FixturePlaybackFailure(message: "Synthetic source is missing video or audio")
        }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        let audio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        video.alwaysCopiesSampleData = false
        audio.alwaysCopiesSampleData = false
        guard reader.canAdd(video), reader.canAdd(audio) else {
            throw FixturePlaybackFailure(message: "Source reader cannot provide decoded video and PCM")
        }
        reader.add(video)
        reader.add(audio)
        guard reader.startReading() else {
            throw reader.error ?? FixturePlaybackFailure(message: "Source reader did not start")
        }
        defer { reader.cancelReading() }
        var nextVideo = video.copyNextSampleBuffer()
        var nextAudio = audio.copyNextSampleBuffer()
        // This prepares a finalized fixture, not a wall-clock capture source. Encoder
        // readiness may legitimately take longer than the production two-second arrival
        // watchdog on a cold simulator. Keep the PTS checks and bounded feed/readiness
        // deadlines; real arrival failure is exercised by tests/hls-writer/watchdog.swift.
        let deadline = CACurrentMediaTime() + 45
        var videoCount = 0
        var audioCount = 0
        let feedStarted = CACurrentMediaTime()
        var readinessSeconds = 0.0
        var appendSeconds = 0.0
        var readSeconds = 0.0
        defer {
            print("Fixture feed diagnostic: video=\(videoCount), audio=\(audioCount), elapsed=\(CACurrentMediaTime() - feedStarted), readiness=\(readinessSeconds), append=\(appendSeconds), read=\(readSeconds), readerStatus=\(reader.status.rawValue), readerError=\(String(describing: reader.error)), writer=\(writer.diagnostic())")
        }
        while nextVideo != nil || nextAudio != nil {
            try Task.checkCancellation()
            guard CACurrentMediaTime() < deadline else {
                throw FixturePlaybackFailure(message: "Source feed exceeded its 45-second deadline")
            }
            let useVideo = nextVideo != nil && (nextAudio == nil ||
                CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(nextVideo!),
                              CMSampleBufferGetPresentationTimeStamp(nextAudio!)) <= 0)
            let type: AVMediaType = useVideo ? .video : .audio
            let sample = useVideo ? nextVideo! : nextAudio!
            let readinessStarted = CACurrentMediaTime()
            let readinessDeadline = CACurrentMediaTime() + 5
            while !queue.sync(execute: { writer.isReadyFor(type) }) {
                guard CACurrentMediaTime() < min(readinessDeadline, deadline) else {
                    throw FixturePlaybackFailure(message: "Real encoder did not become ready for \(type.rawValue)")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            readinessSeconds += CACurrentMediaTime() - readinessStarted
            let appendStarted = CACurrentMediaTime()
            try queue.sync { try writer.append(sample, type: type) }
            appendSeconds += CACurrentMediaTime() - appendStarted
            let readStarted = CACurrentMediaTime()
            if useVideo {
                videoCount += 1
                nextVideo = video.copyNextSampleBuffer()
            } else {
                audioCount += 1
                nextAudio = audio.copyNextSampleBuffer()
            }
            readSeconds += CACurrentMediaTime() - readStarted
            if useVideo && videoCount % 120 == 0 {
                print("Fixture feed progress: video=\(videoCount), audio=\(audioCount), elapsed=\(CACurrentMediaTime() - feedStarted), readiness=\(readinessSeconds), append=\(appendSeconds), read=\(readSeconds)")
            }
        }
        guard reader.status == .completed, videoCount == 720, audioCount > 0 else {
            throw reader.error ?? FixturePlaybackFailure(message: "Source feed incomplete: \(videoCount) video buffers, \(audioCount) audio buffers")
        }
    }
}

private struct FixturePlaybackFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct DecodedFixtureObservations {
    var decodedFrames = 0
    var darkFrames = 0
    var whiteTimes: [Double] = []
    var firstClock: Double?
    var lastClock: Double?
    private var lastDisplayTime: Double?
    private var sawDarkSinceWhite = false

    var clockProgress: Double { (lastClock ?? 0) - (firstClock ?? 0) }

    mutating func observeClock(_ time: CMTime) {
        guard time.isNumeric else { return }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        if firstClock == nil { firstClock = seconds }
        lastClock = seconds
    }

    mutating func observe(_ pixel: CVPixelBuffer, displayTime: CMTime) throws {
        guard displayTime.isNumeric else {
            throw FixturePlaybackFailure(message: "Decoded frame has no numeric display time")
        }
        let seconds = CMTimeGetSeconds(displayTime)
        guard seconds.isFinite else {
            throw FixturePlaybackFailure(message: "Decoded frame display time is not finite")
        }
        if let previous = lastDisplayTime {
            guard seconds >= previous else {
                throw FixturePlaybackFailure(message: "Decoded frame time regressed: \(previous) -> \(seconds)")
            }
            if seconds == previous { return }
        }
        lastDisplayTime = seconds
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixel) == 854, CVPixelBufferGetHeight(pixel) == 480 else {
            throw FixturePlaybackFailure(message: "Decoded output did not preserve the fixture's BGRA 854x480 image")
        }
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
            throw FixturePlaybackFailure(message: "Cannot read decoded pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else {
            throw FixturePlaybackFailure(message: "Decoded buffer has no readable pixels")
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        // White flashes occupy x=40...219, y=40...219. Read an interior patch,
        // plus a separate known dark patch, not whole-frame mean brightness.
        func patchBrightness(x: Int, y: Int) -> Double {
            var sum = 0
            for row in y..<(y + 8) {
                for column in x..<(x + 8) {
                    let position = row * stride + column * 4
                    sum += Int(bytes[position]) + Int(bytes[position + 1]) + Int(bytes[position + 2])
                }
            }
            return Double(sum) / Double(8 * 8 * 3)
        }
        let roi = patchBrightness(x: 96, y: 96)
        let background = patchBrightness(x: 700, y: 350)
        guard background < 80 else {
            throw FixturePlaybackFailure(message: "Known dark background is absent from decoded image: \(background)")
        }
        decodedFrames += 1
        if roi < 80 {
            darkFrames += 1
            sawDarkSinceWhite = true
        } else if roi > 200, sawDarkSinceWhite {
            whiteTimes.append(seconds)
            sawDarkSinceWhite = false
        }
    }
}
