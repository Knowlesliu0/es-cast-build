import SwiftUI
import AVKit
import UniformTypeIdentifiers
import Combine

@main
struct ESCastApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var capture = CaptureModel()
    @StateObject private var playback = PlaybackModel()
    @StateObject private var relay = LiveRelayModel()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
#if SOURCE_RECOVERY_OBSERVATION
                    Text("來源恢復觀察診斷版").font(.headline)
                    Text("來源逾時後，串流會停止；最多再觀察 15 秒並保存診斷。這不代表播放問題已修復。")
#endif
                    Text("車機影片與即時投放測試")
                        .font(.headline)
                    Text("先測車機能否接收影片，再測紅果即時投放。可保持勿擾與駕駛專注模式關閉；結果會保存在手機，車上不需要電腦。")
                    Text("影片測試請在停車時進行。")
                        .foregroundStyle(.secondary)
                }
                Section("車機影片接收測試") {
                    Text("先載入內建測試片，點右側 AirPlay 選擇影片接收端，再按播放。先確認車機有畫面與短音，結束後按保存播放診斷。")
                    Button("載入內建測試片", action: playback.loadCarTestMovie)
                        .disabled(capture.active || capture.busy || playback.active || relay.armed)
                    Button("匯入測試影片") { importing = true }
                        .disabled(capture.active || capture.busy || playback.active || relay.armed)
                    if !capture.active && !relay.armed {
                        VideoPlayer(player: playback.player).frame(height: 180)
                            .disabled(capture.busy)
                    } else {
                        Text("即時投放期間，請在車機查看影片。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("播放", action: playback.play)
                            .disabled(!playback.ready || capture.active || capture.busy)
                        Button("暫停", action: playback.pause)
                        Spacer()
                        AirPlayPicker().frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(capture.active || capture.busy || relay.armed)
                    Text(playback.status)
                    Text(playback.externalPlayback ? "系統回報外部播放中，仍須目視確認車機影像。" : "尚未回報外部影片播放。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存播放診斷", action: playback.saveDiagnostic)
                        .disabled(capture.active || capture.busy || relay.armed)
                    if let url = playback.diagnosticURL { ShareLink("匯出播放診斷", item: url) }
                }
                Section("單一 App 即時投放") {
                    Text(relay.status)
                    Button("準備即時投放") {
                        playback.pause()
                        if relay.prepare() { capture.liveStreaming = true }
                    }.disabled(capture.active || capture.busy || relay.armed)
                    HStack {
                        Text("選擇影片接收端")
                        Spacer()
                        AirPlayPicker().frame(width: 44, height: 44)
                    }.disabled(!relay.armed || capture.active || capture.busy)
                    Button("開始即時投放") { capture.chooseScreen() }
                        .disabled(!relay.armed || capture.active || capture.busy)
                    Button("取消投放準備") { relay.stop(reason: "user_cancelled") }
                        .disabled(!relay.armed || capture.active || capture.busy)
                    Text("準備後先選擇影片接收端，再開始全螢幕分享、收起系統視窗並切到紅果。沒有外部影片接收端時，轉送播放器會保持靜音，只測手機串流。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = relay.logURL { ShareLink("匯出即時投放診斷", item: url) }
                }
                Section("擷取與保存") {
                    Text(capture.status)
                    Text(capture.summary).font(.system(.caption, design: .monospaced))
                    Toggle("啟動即時發送", isOn: $capture.liveStreaming)
                        .disabled(capture.active || capture.busy || relay.armed)
                    Toggle("保存本機測試錄影", isOn: $capture.saveRecording)
                        .disabled(capture.active || capture.busy)
                    Text("系統全螢幕分享可能包含通知。串流僅供手機自身讀取；開啟錄影才保存 MP4 與最近的串流分段，不上傳影音。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("僅開始擷取（備用接收端）") {
                        playback.pause()
                        capture.chooseScreen()
                    }.disabled(capture.active || capture.busy || relay.armed)
                    Button("停止擷取") {
                        relay.stop(reason: "user")
                        Task { await capture.stop() }
                    }
                        .disabled(!capture.active || capture.busy)
                    if let url = capture.logURL { ShareLink("匯出測試紀錄", item: url) }
                    if let url = capture.recordingURL { ShareLink("匯出已完成錄影", item: url) }
                }
                if capture.liveStreaming {
                    DisclosureGroup("rPlay TV 備用接收設定") {
                        Text(capture.liveStatus)
                        Text(capture.playlistURL.absoluteString)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("複製 rPlay TV 網址") { UIPasteboard.general.string = capture.playlistURL.absoluteString }
                        Text("在 rPlay TV 新增 M3U 清單，貼上網址並測試連線。開始分享後先收起提示窗，再切到紅果；車機播放請在停車時測試。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("驗收") {
                    Text("至少測試 30 分鐘。樣本計數不能證明畫面沒有黑屏，也不能測出車機影音差。實車測試須一起錄下螢幕閃光與喇叭短音。")
                }
            }
            .navigationTitle("ES Cast 驗證版")
            .onReceive(Publishers.CombineLatest4(capture.$active, capture.$liveReady,
                                                capture.$liveSessionID, capture.$busy)) { _ in
                // Published values are sent before assignment; re-read after the actor hop.
                Task { @MainActor in
                    relay.updateCapture(active: capture.active, ready: capture.liveReady,
                                        sessionID: capture.liveSessionID, pickerBusy: capture.busy)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: false,
                          onCompletion: playback.importMovie)
        }
    }
}

private struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
