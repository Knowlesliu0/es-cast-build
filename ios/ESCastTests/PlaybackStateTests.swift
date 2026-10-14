import AVFoundation
import XCTest
@testable import ESCastTestHost

final class PlaybackStateTests: XCTestCase {
    @MainActor
    func testIdleMoviePlayerDoesNotHandleLiveRelayRouteLoss() async throws {
        let movie = PlaybackModel()
        let relay = LiveRelayModel()
        XCTAssertTrue(relay.prepare(), relay.status)
        defer { relay.stop(reason: "test_cleanup") }
        let idleStatus = movie.status
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(movie.status, idleStatus,
                       "An idle MP4 player must leave the live relay's route change alone")
        XCTAssertTrue(relay.armed)
    }

    @MainActor
    func testBuiltInCarMovieLoadsSixtySecondsOfVideoAndAudio() async throws {
        let model = PlaybackModel()
        model.loadCarTestMovie()
        defer { model.pause() }
        let item = try XCTUnwrap(model.player.currentItem, model.status)
        let duration = try await item.asset.load(.duration)
        let video = try await item.asset.loadTracks(withMediaType: .video)
        let audio = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(CMTimeGetSeconds(duration), 60, accuracy: 0.1)
        XCTAssertFalse(video.isEmpty)
        XCTAssertFalse(audio.isEmpty)
        model.play()
        let deadline = Date().addingTimeInterval(5)
        while model.player.currentTime().seconds < 0.15, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertGreaterThan(model.player.currentTime().seconds, 0.1,
                             "The bundled resource must advance the real AVPlayer clock")
    }

    @MainActor
    func testPauseDoesNotKeepClaimingPlaybackIsRunning() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try Data("invalid movie for the state test".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = PlaybackModel()
        model.importMovie(.success([source]))
        XCTAssertTrue(model.ready)
        model.play()
        model.pause()

        XCTAssertFalse(model.active)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertFalse(model.status.contains("播放中"),
                       "A paused player must not tell the user that playback is running")
    }

    @MainActor
    func testUnreadableMovieReportsFailureInsteadOfRunningForever() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try Data("invalid movie for the state test".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = PlaybackModel()
        model.importMovie(.success([source]))
        model.play()
        defer { model.pause() }
        let deadline = Date().addingTimeInterval(5)
        while model.player.currentItem?.status != .failed, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.player.currentItem?.status, .failed,
                       "This test must exercise an actual AVPlayerItem decoding failure")
        // AVFoundation state notifications cross onto the main actor asynchronously.
        while !model.status.contains("播放失敗"), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.active)
        XCTAssertTrue(model.status.contains("播放失敗"),
                      "An unreadable imported movie needs an observable failure state")
        XCTAssertFalse(model.status.contains("播放中"))
    }
}
