import AVFoundation
import Combine
import XCTest
@testable import ESCastTestHost

final class LiveRelayLifecycleTests: XCTestCase {
    func testArmWaitsForCaptureInsteadOfTreatingInitialIdleAsCancellation() {
        var gate = LiveRelayCaptureGate()
        XCTAssertEqual(gate.update(active: false, ready: false, sessionID: nil, pickerBusy: false), .wait)
        XCTAssertEqual(gate.update(active: false, ready: false, sessionID: nil, pickerBusy: false), .wait)
    }

    func testCancelledPickerEndsArmWithoutStartingAnItem() {
        var gate = LiveRelayCaptureGate()
        XCTAssertEqual(gate.update(active: false, ready: false, sessionID: nil, pickerBusy: true), .wait)
        XCTAssertEqual(gate.update(active: false, ready: false, sessionID: nil, pickerBusy: false),
                       .stop("picker_cancelled"))
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: UUID(), pickerBusy: false), .wait)
    }

    func testActiveCaptureMustHaveItsSessionIdentityBeforeStarting() {
        var gate = LiveRelayCaptureGate()
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: nil, pickerBusy: true), .wait)
        let session = UUID()
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: session, pickerBusy: false),
                       .start(session))
    }

    func testReadyStartsTheCurrentSessionExactlyOnce() {
        var gate = LiveRelayCaptureGate()
        let session = UUID()
        XCTAssertEqual(gate.update(active: true, ready: false, sessionID: session, pickerBusy: true), .wait)
        XCTAssertEqual(gate.update(active: true, ready: false, sessionID: session, pickerBusy: false), .wait)
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: session, pickerBusy: false),
                       .start(session))
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: session, pickerBusy: false), .wait)
    }

    func testLossOfReadinessEndsConsumerAndNeverRestartsIt() {
        var gate = LiveRelayCaptureGate()
        let session = UUID()
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: session, pickerBusy: false),
                       .start(session))
        XCTAssertEqual(gate.update(active: true, ready: false, sessionID: session, pickerBusy: false),
                       .stop("capture_not_ready"))
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: session, pickerBusy: false), .wait)
    }

    func testCaptureStopEndsConsumer() {
        var gate = LiveRelayCaptureGate()
        let session = UUID()
        _ = gate.update(active: true, ready: true, sessionID: session, pickerBusy: false)
        XCTAssertEqual(gate.update(active: false, ready: false, sessionID: session, pickerBusy: true),
                       .stop("capture_stopped"))
    }

    func testDifferentCaptureSessionCannotReplaceAnArmedConsumersSource() {
        var gate = LiveRelayCaptureGate()
        let first = UUID()
        _ = gate.update(active: true, ready: false, sessionID: first, pickerBusy: false)
        XCTAssertEqual(gate.update(active: true, ready: true, sessionID: UUID(), pickerBusy: false),
                       .stop("capture_session_changed"))
    }

    @MainActor
    func testPreparationUsesDefaultMixingWithoutStartingAnItem() {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let audio = AVAudioSession.sharedInstance()
        XCTAssertEqual(audio.routeSharingPolicy, .default)
        XCTAssertTrue(audio.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertNil(model.player.currentItem)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertEqual(model.player.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)
    }

    @MainActor
    func testLateCaptureReadyCannotRestartAStoppedArm() {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        model.stop(reason: "user")
        model.updateCapture(active: true, ready: true, sessionID: UUID(), pickerBusy: false)
        XCTAssertFalse(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertNil(model.player.currentItem)
    }

    @MainActor
    func testDiagnosticIsOfferedForExportOnlyAfterClosingTheRun() {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        XCTAssertNil(model.logURL)
        model.stop(reason: "user")
        XCTAssertNotNil(model.logURL)
    }

    @MainActor
    func testRetiredItemFailureCannotEndCurrentArm() async {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let retired = AVPlayerItem(asset: AVMutableComposition())
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let originalStatus = model.status
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: retired)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertEqual(model.status, originalStatus)
        XCTAssertTrue(model.player.currentItem === current)
    }

    @MainActor
    func testQueuedFailureFromPreviousArmCannotEndNewArm() async {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        let retired = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: retired)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: retired)
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertTrue(model.player.currentItem === current)
    }

    @MainActor
    func testCurrentItemFailureStopsAndPersistsLocalDiagnostic() async throws {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let stopped = expectation(description: "Current item failure must end this arm")
        let observation = model.$armed.dropFirst().sink { if !$0 { stopped.fulfill() } }
        defer { observation.cancel() }
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: current)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(model.active)
        XCTAssertNil(model.player.currentItem)
        XCTAssertTrue(model.player.isMuted)
        let log = try String(contentsOf: XCTUnwrap(model.logURL), encoding: .utf8)
        let rows = try log.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.last?["event"] as? String, "stop")
        XCTAssertEqual(rows.last?["reason"] as? String, "item_failed_to_end")
        XCTAssertEqual(rows.last?["vehicle_playback_verified"] as? Bool, false)
        XCTAssertEqual(rows.last?["audible_output_verified"] as? Bool, false)
    }
}
