import SwiftUI
import AVKit

@MainActor
final class PlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var status = "請匯入同步測試影片"
    @Published private(set) var ready = false
    @Published private(set) var active = false
    @Published private(set) var externalPlayback = false
    @Published private(set) var diagnosticURL: URL?
    private var importedURL: URL?
    private var observers: [NSObjectProtocol] = []
    private var externalObserver: NSKeyValueObservation?
    private var resumeAfterInterruption = false

    init() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        externalObserver = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            let external = player.isExternalPlaybackActive
            Task { @MainActor in self?.externalPlayback = external }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self?.pause()
                self?.status = "接收端已斷線，請重新選擇接收端後播放"
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                // Recheck after the actor hop: the user may have selected another item.
                guard let self, let item, self.player.currentItem === item else { return }
                self.pause()
                self.status = "播放失敗：\(message ?? "原因未提供")"
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.active = false
                self.status = "測試影片已播完，請核對實際車機紀錄"
            }
        })
    }

    func importMovie(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let folder = URL.documentsDirectory.appending(path: "PlaybackTests")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            pause()
            player.replaceCurrentItem(with: AVPlayerItem(url: destination))
            if let old = importedURL { try? FileManager.default.removeItem(at: old) }
            importedURL = destination
            ready = true
            status = "已匯入；點選 AirPlay 接收端後播放"
        } catch { status = "匯入失敗：\(error.localizedDescription)" }
    }

    func play() {
        guard ready else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                                    policy: .longFormVideo, options: [])
            try session.setActive(true)
            player.play()
            active = true
            status = "播放中；請確認接收端有影像，只有聲音不算通過"
        } catch { status = "無法開始播放：\(error.localizedDescription)" }
    }

    func pause() {
        player.pause()
        active = false
        resumeAfterInterruption = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A user-requested local snapshot, not proof of receiver decoding or vehicle sync.
    func saveDiagnostic() {
        do {
            let session = AVAudioSession.sharedInstance()
            let item = player.currentItem
            let itemError = item?.error as NSError?
            let time = CMTimeGetSeconds(player.currentTime())
            let report: [String: Any] = [
                "observed_at": ISO8601DateFormatter().string(from: Date()),
                "snapshot_only": true,
                "app_bundle_id": Bundle.main.bundleIdentifier ?? "",
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
                "status": status, "ready": ready, "requested_playback_active": active,
                "external_playback_active": player.isExternalPlaybackActive,
                "player_item_status": item?.status.rawValue ?? -1,
                "time_control_status": player.timeControlStatus.rawValue,
                "player_rate": player.rate,
                "player_time_seconds": time.isFinite ? time : NSNull(),
                "route_sharing_policy": session.routeSharingPolicy.rawValue,
                "audio_category": session.category.rawValue,
                "audio_outputs": session.currentRoute.outputs.map { $0.portType.rawValue },
                "error_domain": itemError?.domain ?? "",
                "error_code": itemError?.code ?? 0,
                "error_message": itemError?.localizedDescription ?? "",
                "vehicle_playback_verified": false, "vehicle_av_sync_verified": false
            ]
            let folder = URL.documentsDirectory.appending(path: "PlaybackDiagnostics")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: UUID().uuidString).appendingPathExtension("json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
            diagnosticURL = url
        } catch { status = "無法保存播放診斷：\(error.localizedDescription)" }
    }

    private func interruption(type: UInt?, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            resumeAfterInterruption = active
            player.pause()
            active = false
            status = "系統音訊中斷，已暫停"
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let resume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            resumeAfterInterruption = false
            if resume { play() }
            else { status = "中斷已結束，請按播放繼續" }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        externalObserver?.invalidate()
    }
}
