import Foundation

actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
    var count: Int { waiting.count }
}

@main struct LifecycleTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        let error = NSError(domain: "ESCast.HLS", code: 12)
        let session = UUID()
        let timer = Gate(), encoder = Gate()
        var now = 100.0
        var httpStops = 0, finishes = 0, captureStops: [UUID] = []
        let coordinator = SourceRecoveryCoordinator(sessionID: session, now: { now }, sleep: { _ in await timer.wait() })
        let begin = {
            coordinator.begin(error: error, failureUptime: 100, stopStreaming: { httpStops += 1 },
                finishEncoder: { finishes += 1; await encoder.wait(); return .failure(error) },
                expired: { captureStops.append($0) })
        }
        check(begin(), "首次故障開始觀察")
        check(httpStops == 1 && captureStops.isEmpty, "立即關閉 HTTP 但保留 capture")
        check(!begin() && httpStops == 1, "重入不重複關閉或收尾")
        for _ in 0..<100 {
            let timerWaiting = await timer.count
            let encoderWaiting = await encoder.count
            if timerWaiting == 1 && encoderWaiting == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(finishes == 1, "encoder 只開始一次收尾")
        now = 115
        await timer.release()
        for _ in 0..<100 {
            if !captureStops.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(captureStops == [session], "15 秒期限不等待 encoder 完成")
        coordinator.close()
        await encoder.release()
        if case .failure(let saved)? = await coordinator.waitForEncoder() {
            check(saved as NSError === error, "保留原始 encoder 結果")
        } else { check(false, "唯一 encoder 任務的結果可供 finalizer 等待") }
        check(coordinator.firstError === error, "關閉後仍保留首個錯誤")
        check(!begin(), "關閉後不得重新開始")

        let oldTimer = Gate()
        var staleStops = 0
        let cancelled = SourceRecoveryCoordinator(sessionID: UUID(), now: { now }, sleep: { _ in await oldTimer.wait() })
        check(cancelled.begin(error: error, failureUptime: now, stopStreaming: {},
                              finishEncoder: { .success(()) }, expired: { _ in staleStops += 1 }), "取消案例開始")
        for _ in 0..<100 {
            if await oldTimer.count == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        cancelled.close() // 手動或系統先停止；即使 sleep 忽略 cancellation 也不得再 stop。
        now += 15
        await oldTimer.release()
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(staleStops == 0, "晚到期限不得停止已關閉 session")
        _ = await cancelled.waitForEncoder()
        print("source recovery lifecycle: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
