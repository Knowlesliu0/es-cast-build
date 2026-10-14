import SwiftUI
import AVKit
import UniformTypeIdentifiers

@main
struct ESCastApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var capture = CaptureModel()
    @StateObject private var playback = PlaybackModel()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
#if SOURCE_RECOVERY_OBSERVATION
                    Text("來源恢復觀察診斷版").font(.headline)
                    Text("來源逾時後，串流會停止；最多再觀察 15 秒並保存診斷。這不代表播放問題已修復。")
#endif
                    Text("紅果即時發送測試")
                        .font(.headline)
                    Text("提供本機影音串流給既有 rPlay TV；車機相容性與同步仍待實測。可保持勿擾與駕駛專注模式關閉。")
                    Text("影片測試請在停車時進行。")
                        .foregroundStyle(.secondary)
                }
                Section("1 · 紅果影音擷取") {
                    Text(capture.status)
                    Text(capture.summary).font(.system(.caption, design: .monospaced))
                    Toggle("啟動即時發送", isOn: $capture.liveStreaming)
                        .disabled(capture.active || capture.busy)
                    Toggle("保存本機測試錄影", isOn: $capture.saveRecording)
                        .disabled(capture.active || capture.busy)
                    Text("系統全螢幕分享可能包含通知。串流僅供手機自身讀取；開啟錄影才保存 MP4 與最近的串流分段，不上傳影音。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("選擇螢幕並開始") {
                        playback.pause()
                        capture.chooseScreen()
                    }.disabled(capture.active || capture.busy)
                    Button("停止擷取") { Task { await capture.stop() } }
                        .disabled(!capture.active || capture.busy)
                    if let url = capture.logURL { ShareLink("匯出測試紀錄", item: url) }
                    if let url = capture.recordingURL { ShareLink("匯出已完成錄影", item: url) }
                }
                if capture.liveStreaming {
                    Section("rPlay TV 接收設定") {
                        Text(capture.liveStatus)
                        Text(capture.playlistURL.absoluteString)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("複製 rPlay TV 網址") { UIPasteboard.general.string = capture.playlistURL.absoluteString }
                        Text("在 rPlay TV 新增 M3U 清單，貼上網址並測試連線。開始分享後先收起提示窗，再切到紅果；車機播放請在停車時測試。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("2 · 接收端播放測試") {
                    Text("先停止擷取，再匯入同步測試影片，透過系統 AirPlay 選擇接收端。")
                    Button("匯入測試影片") { importing = true }
                        .disabled(capture.active || capture.busy || playback.active)
                    VideoPlayer(player: playback.player)
                        .frame(height: 180)
                        .disabled(capture.active || capture.busy)
                    HStack {
                        Button("播放", action: playback.play)
                            .disabled(!playback.ready || capture.active || capture.busy)
                        Button("暫停", action: playback.pause)
                        Spacer()
                        AirPlayPicker().frame(width: 44, height: 44)
                    }.disabled(capture.active || capture.busy)
                    Text(playback.status)
                    Text(playback.externalPlayback ? "系統回報外部播放中，仍須目視確認車機影像。" : "尚未回報外部影片播放。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存播放診斷", action: playback.saveDiagnostic)
                        .disabled(capture.active || capture.busy)
                    if let url = playback.diagnosticURL { ShareLink("匯出播放診斷", item: url) }
                }
                Section("驗收") {
                    Text("至少測試 30 分鐘。樣本計數不能證明畫面沒有黑屏，也不能測出車機影音差。實車測試須一起錄下螢幕閃光與喇叭短音。")
                }
            }
            .navigationTitle("ES Cast 驗證版")
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
