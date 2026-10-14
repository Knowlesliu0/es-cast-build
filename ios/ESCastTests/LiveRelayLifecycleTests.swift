import AVFoundation
import Combine
import CoreFoundation
import UIKit
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
    func testDiagnosticSamplesContinueDuringTrackingWithoutStartingPlayback() async throws {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let ticks = pumpTrackingMode(for: 3.2)
        XCTAssertGreaterThanOrEqual(ticks.common, 20, "The tracking loop must actually process timers")
        XCTAssertEqual(ticks.defaultOnly, 0, "The probe must not fall back to the default mode")
        // Drain any MainActor tasks posted by timers during the nested tracking loop.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertNil(model.player.currentItem)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertEqual(model.player.rate, 0)
        model.stop(reason: "user")
        let rows = try closedDiagnosticRows(model)
        let samples = rows.filter { $0["event"] as? String == "sample" }
        XCTAssertGreaterThanOrEqual(samples.count, 3,
                                   "Interface tracking must not suppress the relay's one-second diagnostic samples")
        XCTAssertEqual(rows.last?["event"] as? String, "stop")
        XCTAssertEqual(rows.last?["reason"] as? String, "user")
        XCTAssertFalse(samples.contains { $0["vehicle_playback_verified"] as? Bool == true })
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

    @MainActor
    func testMatchingBackgroundRateNotificationIsSavedWithoutChangingTheArm() async throws {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let expectedRate = model.player.rate
        let originalStatus = model.status
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: model.player,
                                        userInfo: [AVPlayer.rateDidChangeReasonKey:
                                                    AVPlayer.RateDidChangeReason.appBackgrounded])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertTrue(model.player.currentItem === current)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertEqual(model.player.rate, expectedRate)
        XCTAssertEqual(model.status, originalStatus)
        model.stop(reason: "user")
        let rows = try closedDiagnosticRows(model)
        let backgroundRows = rows.filter {
            $0["event"] as? String == "rate_changed"
                && $0["notification_reason_raw"] as? String == AVPlayer.RateDidChangeReason.appBackgrounded.rawValue
        }
        XCTAssertEqual(backgroundRows.count, 1, "The matching AVPlayer notification must survive in the closed diagnostic")
        guard let row = backgroundRows.first else { return }
        XCTAssertEqual(row["notification_reason_name"] as? String, "appBackgrounded")
        XCTAssertEqual((row["notification_player_rate"] as? NSNumber)?.floatValue, expectedRate)
        XCTAssertEqual(row["consumer_muted"] as? Bool, true)
        XCTAssertEqual(row["armed"] as? Bool, true)
        XCTAssertEqual(row["vehicle_playback_verified"] as? Bool, false)
        XCTAssertEqual(row["audible_output_verified"] as? Bool, false)
        XCTAssertEqual(rows.first?["event"] as? String, "prepared")
        XCTAssertEqual(rows.last?["event"] as? String, "stop")
        XCTAssertEqual(rows.last?["reason"] as? String, "user")
    }

    @MainActor
    func testRateDiagnosticPreservesUnknownReasonAndDistinguishesMissingReason() async throws {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let unknownRaw = "ESCastTests.futureRateReason"
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: model.player,
                                        userInfo: [AVPlayer.rateDidChangeReasonKey:
                                                    AVPlayer.RateDidChangeReason(rawValue: unknownRaw)])
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: model.player)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertNil(model.player.currentItem)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertEqual(model.player.rate, 0)
        model.stop(reason: "user")
        let rows = try closedDiagnosticRows(model).filter { $0["event"] as? String == "rate_changed" }
        let unknownRows = rows.filter { $0["notification_reason_raw"] as? String == unknownRaw }
        XCTAssertEqual(unknownRows.count, 1, "Unrecognized Apple reason values must remain inspectable")
        XCTAssertEqual(unknownRows.first?["notification_reason_name"] as? String, "unknown")
        let missingRows = rows.filter { $0["notification_reason_name"] as? String == "missing" }
        XCTAssertEqual(missingRows.count, 1, "A notification without reason must not be silently discarded")
        XCTAssertTrue(missingRows.first?["notification_reason_raw"] is NSNull)
    }

    @MainActor
    func testOtherPlayersRateNotificationCannotPolluteThisRunsDiagnostic() async throws {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let otherPlayer = AVPlayer()
        let foreignRaw = "ESCastTests.foreignPlayerRate"
        let matchingRaw = "ESCastTests.matchingPlayerRate"
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: otherPlayer,
                                        userInfo: [AVPlayer.rateDidChangeReasonKey:
                                                    AVPlayer.RateDidChangeReason(rawValue: foreignRaw)])
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: model.player,
                                        userInfo: [AVPlayer.rateDidChangeReasonKey:
                                                    AVPlayer.RateDidChangeReason(rawValue: matchingRaw)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertTrue(model.player.currentItem === current)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertEqual(model.player.rate, 0)
        model.stop(reason: "user")
        let rows = try closedDiagnosticRows(model).filter { $0["event"] as? String == "rate_changed" }
        XCTAssertFalse(rows.contains { $0["notification_reason_raw"] as? String == foreignRaw })
        XCTAssertEqual(rows.filter { $0["notification_reason_raw"] as? String == matchingRaw }.count, 1,
                       "The positive control proves the observer did not simply ignore every player")
    }

    @MainActor
    func testQueuedRateNotificationFromPreviousArmCannotPolluteRearmedRun() async throws {
        let model = LiveRelayModel()
        XCTAssertTrue(model.prepare(), model.status)
        let previousRaw = "ESCastTests.previousGenerationRate"
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: model.player,
                                        userInfo: [AVPlayer.rateDidChangeReasonKey:
                                                    AVPlayer.RateDidChangeReason(rawValue: previousRaw)])
        // Re-arm before the notification's MainActor task can run. The AVPlayer identity is unchanged.
        XCTAssertTrue(model.prepare(), model.status)
        defer { model.stop(reason: "test_cleanup") }
        let current = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: current)
        let currentRaw = "ESCastTests.currentGenerationRate"
        NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: model.player,
                                        userInfo: [AVPlayer.rateDidChangeReasonKey:
                                                    AVPlayer.RateDidChangeReason(rawValue: currentRaw)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.armed)
        XCTAssertFalse(model.active)
        XCTAssertTrue(model.player.currentItem === current)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertEqual(model.player.rate, 0)
        model.stop(reason: "user")
        let rows = try closedDiagnosticRows(model).filter { $0["event"] as? String == "rate_changed" }
        XCTAssertFalse(rows.contains { $0["notification_reason_raw"] as? String == previousRaw })
        XCTAssertEqual(rows.filter { $0["notification_reason_raw"] as? String == currentRaw }.count, 1,
                       "The new arm must still accept a matching notification")
    }

    @MainActor
    private func closedDiagnosticRows(_ model: LiveRelayModel) throws -> [[String: Any]] {
        let log = try String(contentsOf: XCTUnwrap(model.logURL), encoding: .utf8)
        return try log.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @MainActor
    private func pumpTrackingMode(for duration: TimeInterval) -> (common: Int, defaultOnly: Int) {
        let counter = TrackingTimerCounter()
        let common = Timer(timeInterval: 0.1, repeats: true) { _ in counter.incrementCommon() }
        let defaultOnly = Timer(timeInterval: 0.1, repeats: true) { _ in counter.incrementDefault() }
        RunLoop.main.add(common, forMode: .common)
        RunLoop.main.add(defaultOnly, forMode: .default)
        defer { common.invalidate(); defaultOnly.invalidate() }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .tracking, before: deadline)
        }
        return counter.read()
    }
}

/// Test-only probes; locking keeps Foundation's Sendable timer closures explicit.
private final class TrackingTimerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var common = 0
    private var defaultOnly = 0
    func incrementCommon() { lock.lock(); defer { lock.unlock() }; common += 1 }
    func incrementDefault() { lock.lock(); defer { lock.unlock() }; defaultOnly += 1 }
    func read() -> (common: Int, defaultOnly: Int) {
        lock.lock(); defer { lock.unlock() }; return (common, defaultOnly)
    }
}
