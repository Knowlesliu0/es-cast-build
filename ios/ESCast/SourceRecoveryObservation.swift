import Foundation

/// 單調時鐘驅動的診斷觀察狀態；尚未接入正式擷取流程。
struct SourceRecoveryObservation {
    let sessionID: UUID
    private(set) var deadline: Double?
    private(set) var firstError: NSError?
    private var closed = false

    init(sessionID: UUID) { self.sessionID = sessionID }

    mutating func begin(error: NSError, now: Double) -> Bool {
        guard !closed, firstError == nil, now.isFinite,
              error.domain == "ESCast.HLS", error.code == 12 else { return false }
        firstError = error
        deadline = now + 15
        return true
    }

    func isDue(now: Double) -> Bool {
        guard !closed, now.isFinite, let deadline else { return false }
        return now >= deadline
    }

    mutating func close() { closed = true }
}
