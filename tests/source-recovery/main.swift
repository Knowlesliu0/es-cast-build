import Foundation

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); failures += 1 }
}

let id = UUID()
let first = NSError(domain: "ESCast.HLS", code: 12, userInfo: ["trigger": "first"])
var state = SourceRecoveryObservation(sessionID: id)
check(!state.isDue(now: 1_000), "未開始時沒有期限")
check(!state.begin(error: NSError(domain: "ESCast.HLS", code: 11), now: 99), "零來源錯誤不得延後停止")
check(!state.begin(error: NSError(domain: "Other", code: 12), now: 99), "其他領域不得進入觀察")
check(state.begin(error: first, now: 100), "首次 HLS 12 必須開始觀察")
check(state.sessionID == id, "保留 session 身分")
check(state.deadline == 115, "從首次錯誤固定觀察 15 秒")
check(!state.isDue(now: 114.999), "期限前不得停止")
check(state.isDue(now: 115), "期限當下停止")
check(state.isDue(now: 200), "排程延遲後仍到期")
check(!state.begin(error: NSError(domain: "ESCast.HLS", code: 12), now: 110), "重複錯誤不得重啟")
check(state.deadline == 115, "重複錯誤不得延長期限")
check(state.firstError === first, "保留原始錯誤物件")
state.close()
check(!state.isDue(now: 200), "關閉後丟棄晚到的期限工作")
check(!state.begin(error: first, now: 201), "關閉是終態")
check(state.firstError === first && state.deadline == 115, "關閉後保留診斷證據")
var cancelled = SourceRecoveryObservation(sessionID: UUID())
cancelled.close()
check(!cancelled.begin(error: first, now: 1), "開始前關閉也不得重新啟動")
var invalidClock = SourceRecoveryObservation(sessionID: UUID())
check(!invalidClock.begin(error: first, now: .nan), "非有限時鐘不能建立永不到期觀察")
check(!invalidClock.begin(error: first, now: .infinity), "無限時鐘不能建立觀察")
check(invalidClock.begin(error: first, now: 10), "無效輸入不得消耗開始機會")
check(!invalidClock.isDue(now: .nan), "無效讀值不得判為到期")
print("source recovery policy: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
