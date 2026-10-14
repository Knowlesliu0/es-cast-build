import Foundation

/// Capture readiness controls a consumer of one live session. A stop is terminal until re-armed.
struct LiveRelayCaptureGate {
    enum Decision: Equatable {
        case wait
        case start(UUID)
        case stop(String)
    }

    private(set) var sessionID: UUID?
    private var sawPickerBusy = false
    private var sawCaptureActive = false
    private var started = false
    private var terminated = false

    mutating func update(active: Bool, ready: Bool, sessionID: UUID?, pickerBusy: Bool) -> Decision {
        guard !terminated else { return .wait }
        if pickerBusy { sawPickerBusy = true }
        if !active {
            if sawCaptureActive { return terminate("capture_stopped") }
            if sawPickerBusy, !pickerBusy { return terminate("picker_cancelled") }
            return .wait
        }
        sawCaptureActive = true
        if let bound = self.sessionID {
            guard sessionID == bound else { return terminate("capture_session_changed") }
        } else {
            // Published capture properties may arrive separately; never start without identity.
            guard let sessionID else { return .wait }
            self.sessionID = sessionID
        }
        if started, !ready { return terminate("capture_not_ready") }
        guard ready, !started, let bound = self.sessionID else { return .wait }
        started = true
        return .start(bound)
    }

    private mutating func terminate(_ reason: String) -> Decision {
        terminated = true
        return .stop(reason)
    }
}
