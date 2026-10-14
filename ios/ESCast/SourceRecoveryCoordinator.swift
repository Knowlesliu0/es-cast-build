import Foundation

/// 診斷專用：只管理固定觀察窗與唯一 encoder 收尾，不恢復串流。
@MainActor
final class SourceRecoveryCoordinator {
    private var observation: SourceRecoveryObservation
    private let now: () -> Double
    private let sleep: (UInt64) async throws -> Void
    private var deadlineTask: Task<Void, Never>?
    private var encoderTask: Task<Result<Void, Error>, Never>?
    init(sessionID: UUID, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        observation = SourceRecoveryObservation(sessionID: sessionID)
        self.now = now
        self.sleep = sleep
    }
    var deadline: Double? { observation.deadline }
    var firstError: NSError? { observation.firstError }
    func begin(error: NSError, failureUptime: Double, stopStreaming: () -> Void,
               finishEncoder: @escaping () async -> Result<Void, Error>,
               expired: @escaping (UUID) async -> Void) -> Bool {
        guard observation.begin(error: error, now: failureUptime), let deadline else { return false }
        stopStreaming()
        encoderTask = Task { await finishEncoder() }
        deadlineTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.observation.isDue(now: self.now()) {
                    self.deadlineTask = nil // finalizer 不可取消自己，否則錄影保存等待也會被取消。
                    await expired(self.observation.sessionID)
                    return
                }
                let remaining = max(0, deadline - self.now())
                // 有界轉換，避免異常時鐘差造成整數溢位。
                let nanos = UInt64(min(15, remaining) * 1_000_000_000)
                do { try await self.sleep(nanos) }
                catch { return }
            }
        }
        return true
    }
    func close() {
        observation.close()
        deadlineTask?.cancel()
        deadlineTask = nil
    }
    func waitForEncoder() async -> Result<Void, Error>? { await encoderTask?.value }
}
