import AVFoundation
import XCTest
@testable import ESCastTestHost

/// Only readiness at the external AVFoundation boundary is controlled. Samples,
/// retiming, encoder, counters, held-image loop and finalization are production code.
final class LiveHLSBackpressureTests: XCTestCase {
    func testTransientHeldVideoPressurePreservesAudioAndRecoversOriginalTimeline() async throws {
        let queue = DispatchQueue(label: "tw.escast.held-pressure-recovery-test")
        let source = try SyntheticLiveMediaSource()
        let store = HLSStore()
        var blockVideo = false // Accessed only on the writer queue.
        let writer = LiveHLSWriter(store: store, queue: queue) { input in
            input.isReadyForMoreMediaData && !(blockVideo && input.mediaType == .video)
        }
        do {
            try await prime(writer, source: source, queue: queue)
            queue.sync { blockVideo = true }
            for index in 1...6 {
                try await appendAudio(index, source: source, writer: writer, queue: queue)
                XCTAssertEqual(writer.diagnostic()["audio_samples"] as? Int, index + 1,
                               "Every audio buffer must be written while a held image is deferred")
                XCTAssertEqual(writer.diagnostic()["video_samples"] as? Int, 1,
                               "No held frame may be appended to a blocked video input")
            }
            queue.sync { blockVideo = false }
            // Two seconds at real cadence give the real encoder time to drain.
            for index in 7...60 {
                try await appendAudio(index, source: source, writer: writer, queue: queue)
            }
            let diagnostic = writer.diagnostic()
            XCTAssertNil(diagnostic["error_code"])
            XCTAssertEqual(diagnostic["audio_samples"] as? Int, 61)
            XCTAssertGreaterThan(diagnostic["held_video_deferrals"] as? Int ?? 0, 0)
            XCTAssertGreaterThan(diagnostic["held_video_recoveries"] as? Int ?? 0, 0)
            let videoPTS = try XCTUnwrap(diagnostic["last_encoded_video_pts"] as? Double)
            let audioPTS = try XCTUnwrap(diagnostic["last_audio_pts"] as? Double)
            XCTAssertEqual(audioPTS, 2, accuracy: 0.000001,
                           "Readiness recovery must not shift or trim the audio timeline")
            XCTAssertGreaterThanOrEqual(videoPTS, 1.9)
            XCTAssertLessThanOrEqual(videoPTS, audioPTS)
            XCTAssertEqual(diagnostic["retained_source_images"] as? Int, 1,
                           "Recovery may retain one source image, never a sample backlog")
            try await writer.finish()
            XCTAssertTrue(writer.diagnostic()["completed"] as? Bool ?? false)
            XCTAssertEqual(writer.diagnostic()["retained_source_images"] as? Int, 0)
        } catch {
            try? await writer.finish()
            throw error
        }
    }

    func testPersistentHeldVideoPressureStopsWithinBoundAndReportsOriginalInput() async throws {
        let queue = DispatchQueue(label: "tw.escast.held-pressure-timeout-test")
        let source = try SyntheticLiveMediaSource()
        var blockVideo = false
        let writer = LiveHLSWriter(store: HLSStore(), queue: queue) { input in
            input.isReadyForMoreMediaData && !(blockVideo && input.mediaType == .video)
        }
        do {
            try await prime(writer, source: source, queue: queue)
            queue.sync { blockVideo = true }
            let began = ProcessInfo.processInfo.systemUptime
            var observed: NSError?
            for index in 1...30 {
                do { try await appendAudio(index, source: source, writer: writer, queue: queue) }
                catch { observed = error as NSError; break }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let failure = try XCTUnwrap(observed, "Persistent pressure must fail rather than wait forever")
            XCTAssertEqual(failure.domain, "ESCast.HLS")
            XCTAssertEqual(failure.code, 14)
            XCTAssertEqual(failure.userInfo["backpressure_input"] as? String, "held_video")
            XCTAssertGreaterThanOrEqual(elapsed, 0.45,
                                       "A single unready result must not terminate capture immediately")
            XCTAssertLessThan(elapsed, 1.5)
            XCTAssertEqual(writer.diagnostic()["held_video_recoveries"] as? Int, 0)
            XCTAssertGreaterThan(writer.diagnostic()["held_video_deferrals"] as? Int ?? 0, 1)
            try? await writer.finish()
            XCTAssertEqual(writer.diagnostic()["retained_source_images"] as? Int, 0)
        } catch {
            try? await writer.finish()
            throw error
        }
    }

    private func prime(_ writer: LiveHLSWriter, source: SyntheticLiveMediaSource,
                       queue: DispatchQueue) async throws {
        let pair = try source.samplePair(frameIndex: 0)
        try queue.sync {
            try writer.append(pair.0, type: .video)
            try writer.append(pair.1, type: .audio)
        }
    }

    private func appendAudio(_ index: Int, source: SyntheticLiveMediaSource,
                             writer: LiveHLSWriter, queue: DispatchQueue) async throws {
        try await Task.sleep(nanoseconds: 33_333_334)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !queue.sync(execute: { writer.isReadyFor(.audio) }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "ESCast.Test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Audio input did not become ready"])
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let pair = try source.samplePair(frameIndex: index)
        try queue.sync { try writer.append(pair.1, type: .audio) }
    }
}
