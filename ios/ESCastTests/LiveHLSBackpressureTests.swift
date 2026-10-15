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
            let pressureAge = try XCTUnwrap(failure.userInfo["backpressure_retry_age_seconds"] as? Double)
            XCTAssertGreaterThanOrEqual(pressureAge, 0.45)
            XCTAssertLessThan(pressureAge, 1,
                              "Scheduling tolerance must not become an unbounded retry policy")
            let diagnostic = writer.diagnostic()
            let videoPTS = try XCTUnwrap(diagnostic["last_encoded_video_pts"] as? Double)
            let audioPTS = try XCTUnwrap(diagnostic["last_audio_pts"] as? Double)
            XCTAssertLessThanOrEqual(audioPTS - videoPTS, 0.5 + 0.000001,
                                    "Do not keep accepting audio beyond the held-video lag budget")
            XCTAssertEqual(writer.diagnostic()["held_video_recoveries"] as? Int, 0)
            XCTAssertGreaterThan(writer.diagnostic()["held_video_deferrals"] as? Int ?? 0, 1)
            try? await writer.finish()
            XCTAssertEqual(writer.diagnostic()["retained_source_images"] as? Int, 0)
        } catch {
            try? await writer.finish()
            throw error
        }
    }

    func testSourceVideoPressureStillFailsOnTheFirstAppend() async throws {
        try await verifyImmediatePressure(.video, expectedInput: "source_video")
    }

    func testAudioPressureStillFailsOnTheFirstAppend() async throws {
        try await verifyImmediatePressure(.audio, expectedInput: "audio")
    }

    func testSourceImageWithinPressureBudgetRecoversWithoutMovingItsTimestamp() async throws {
        try await verifySourceDuringHeldPressure(expired: false)
    }

    func testSourceImageCannotEraseAnExpiredHeldPressureBudget() async throws {
        try await verifySourceDuringHeldPressure(expired: true)
    }

    func testPartialHeldProgressDoesNotResetTheOriginalPressureBudget() async throws {
        let queue = DispatchQueue(label: "tw.escast.partial-held-pressure-test")
        let source = try SyntheticLiveMediaSource()
        var allowance: Int?
        let writer = LiveHLSWriter(store: HLSStore(), queue: queue) { input in
            guard input.isReadyForMoreMediaData else { return false }
            guard input.mediaType == .video, let remaining = allowance else { return true }
            guard remaining > 0 else { return false }
            allowance = remaining - 1
            return true
        }
        do {
            try await prime(writer, source: source, queue: queue)
            queue.sync { allowance = 0 }
            for index in 1...6 {
                try await appendAudio(index, source: source, writer: writer, queue: queue)
            }
            var observed: NSError?
            for index in 7...30 {
                // One held frame per callback makes partial progress but never
                // catches the existing backlog. Its deadline must remain unchanged.
                queue.sync { allowance = 1 }
                do { try await appendAudio(index, source: source, writer: writer, queue: queue) }
                catch { observed = error as NSError; break }
            }
            let failure = try XCTUnwrap(observed, "Partial writes must not buy a new pressure budget")
            XCTAssertEqual(failure.domain, "ESCast.HLS")
            XCTAssertEqual(failure.code, 14)
            XCTAssertEqual(failure.userInfo["backpressure_input"] as? String, "held_video")
            let pressureAge = try XCTUnwrap(failure.userInfo["backpressure_retry_age_seconds"] as? Double)
            XCTAssertGreaterThanOrEqual(pressureAge, 0.5)
            XCTAssertLessThan(pressureAge, 1)
            XCTAssertGreaterThan(writer.diagnostic()["held_video_frames"] as? Int ?? 0, 0,
                                 "The test must actually append held frames between refusals")
            XCTAssertEqual(writer.diagnostic()["held_video_recoveries"] as? Int, 0)
            try? await writer.finish()
        } catch {
            try? await writer.finish()
            throw error
        }
    }

    private func verifySourceDuringHeldPressure(expired: Bool) async throws {
        let queue = DispatchQueue(label: "tw.escast.source-held-budget-test")
        let source = try SyntheticLiveMediaSource()
        var blockVideo = false
        let writer = LiveHLSWriter(store: HLSStore(), queue: queue) { input in
            input.isReadyForMoreMediaData && !(blockVideo && input.mediaType == .video)
        }
        do {
            try await prime(writer, source: source, queue: queue)
            queue.sync { blockVideo = true }
            for index in 1...2 {
                try await appendAudio(index, source: source, writer: writer, queue: queue)
            }
            XCTAssertGreaterThan(writer.diagnostic()["held_video_deferrals"] as? Int ?? 0, 0)
            if expired { try await Task.sleep(nanoseconds: 550_000_000) }
            queue.sync { blockVideo = false }
            let pair = try source.samplePair(frameIndex: 3)
            if expired {
                XCTAssertThrowsError(try queue.sync { try writer.append(pair.0, type: .video) }) { error in
                    let failure = error as NSError
                    XCTAssertEqual(failure.domain, "ESCast.HLS")
                    XCTAssertEqual(failure.code, 14)
                    XCTAssertEqual(failure.userInfo["backpressure_input"] as? String, "held_video")
                }
                XCTAssertEqual(writer.diagnostic()["video_samples"] as? Int, 1)
                XCTAssertEqual(writer.diagnostic()["held_video_recoveries"] as? Int, 0)
            } else {
                try queue.sync { try writer.append(pair.0, type: .video) }
                XCTAssertEqual(writer.diagnostic()["video_samples"] as? Int, 2)
                XCTAssertEqual(writer.diagnostic()["held_video_recoveries"] as? Int, 1)
                XCTAssertEqual(try XCTUnwrap(writer.diagnostic()["last_encoded_video_pts"] as? Double),
                               0.1, accuracy: 0.000001)
                XCTAssertEqual(try XCTUnwrap(writer.diagnostic()["last_audio_pts"] as? Double),
                               2.0 / 30.0, accuracy: 0.000001)
            }
            try? await writer.finish()
        } catch {
            try? await writer.finish()
            throw error
        }
    }

    private func verifyImmediatePressure(_ type: AVMediaType, expectedInput: String) async throws {
        let queue = DispatchQueue(label: "tw.escast.source-pressure-test")
        let source = try SyntheticLiveMediaSource()
        var blocked: AVMediaType?
        let writer = LiveHLSWriter(store: HLSStore(), queue: queue) { input in
            input.isReadyForMoreMediaData && input.mediaType != blocked
        }
        do {
            try await prime(writer, source: source, queue: queue)
            let pair = try source.samplePair(frameIndex: 1)
            queue.sync { blocked = type }
            XCTAssertThrowsError(try queue.sync {
                try writer.append(type == .video ? pair.0 : pair.1, type: type)
            }) { error in
                let failure = error as NSError
                XCTAssertEqual(failure.domain, "ESCast.HLS")
                XCTAssertEqual(failure.code, 14)
                XCTAssertEqual(failure.userInfo["backpressure_input"] as? String, expectedInput)
            }
            XCTAssertEqual(writer.diagnostic()["audio_samples"] as? Int, 1)
            XCTAssertEqual(writer.diagnostic()["video_samples"] as? Int, 1)
            XCTAssertEqual(writer.diagnostic()["held_video_deferrals"] as? Int ?? 0, 0)
            try? await writer.finish()
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
