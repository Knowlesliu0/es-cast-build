import Foundation

/// Capture readiness controls a consumer of one live session. A stop is terminal until re-armed.
struct LiveRelayCaptureGate {
    enum Decision: Equatable {
        case wait
        case start(UUID)
        case stop(String)
    }

    private(set) var sessionID: UUID?

    mutating func update(active: Bool, ready: Bool, sessionID: UUID?, pickerBusy: Bool) -> Decision {
        .wait
    }
}
