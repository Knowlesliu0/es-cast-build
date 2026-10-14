import AVFoundation
import XCTest
@testable import ESCastTestHost

final class PlaybackStateTests: XCTestCase {
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
