import AVFoundation
import Combine
import XCTest
@testable import ESCastTestHost

final class PlaybackNotificationTests: XCTestCase {
    @MainActor
    func testRetiredItemEndDoesNotChangeCurrentPlaybackStatus() async {
        let model = PlaybackModel()
        let retired = AVPlayerItem(asset: AVMutableComposition())
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: retired)
        model.player.replaceCurrentItem(with: current)
        let originalStatus = model.status
        let unwantedChange = expectation(description: "Retired item must not change playback state")
        unwantedChange.isInverted = true
        let observation = model.$status.dropFirst().sink { _ in unwantedChange.fulfill() }
        defer { observation.cancel() }

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: retired)
        await fulfillment(of: [unwantedChange], timeout: 0.3)
        XCTAssertEqual(model.status, originalStatus)
        XCTAssertTrue(model.player.currentItem === current)
    }

    @MainActor
    func testRetiredItemFailureDoesNotChangeCurrentPlaybackStatus() async {
        let model = PlaybackModel()
        let retired = AVPlayerItem(asset: AVMutableComposition())
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let originalStatus = model.status
        let unwantedChange = expectation(description: "Unrelated failure must not affect current item")
        unwantedChange.isInverted = true
        let observation = model.$status.dropFirst().sink { _ in unwantedChange.fulfill() }
        defer { observation.cancel() }

        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: retired)
        await fulfillment(of: [unwantedChange], timeout: 0.3)
        XCTAssertEqual(model.status, originalStatus)
    }

    @MainActor
    func testQueuedFailureIsIgnoredIfItemChangesBeforeDelivery() async {
        let model = PlaybackModel()
        let retired = AVPlayerItem(asset: AVMutableComposition())
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: retired)
        let originalStatus = model.status
        let unwantedChange = expectation(description: "Delayed delivery must recheck the current item")
        unwantedChange.isInverted = true
        let observation = model.$status.dropFirst().sink { _ in unwantedChange.fulfill() }
        defer { observation.cancel() }

        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: retired)
        model.player.replaceCurrentItem(with: current)
        await fulfillment(of: [unwantedChange], timeout: 0.3)
        XCTAssertEqual(model.status, originalStatus)
    }

    @MainActor
    func testMissingItemCannotReportPlaybackCompleted() async {
        let model = PlaybackModel()
        let unwantedChange = expectation(description: "No item means no completion")
        unwantedChange.isInverted = true
        let observation = model.$status.dropFirst().sink { _ in unwantedChange.fulfill() }
        defer { observation.cancel() }

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        await fulfillment(of: [unwantedChange], timeout: 0.3)
    }

    @MainActor
    func testCurrentItemCompletionStillReachesTheModel() async {
        let model = PlaybackModel()
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let originalStatus = model.status
        let completion = expectation(description: "Current item completion must be handled")
        let observation = model.$status.dropFirst().sink { _ in completion.fulfill() }
        defer { observation.cancel() }

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: current)
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertNotEqual(model.status, originalStatus)
        XCTAssertFalse(model.active)
    }
}
