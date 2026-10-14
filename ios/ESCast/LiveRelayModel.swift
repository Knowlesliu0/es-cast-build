import AVFoundation
import Combine
import CoreVideo
import Foundation
import QuartzCore
import UIKit

/// An opt-in consumer of one live capture. No preview, saved media, or automatic restart.
@MainActor
final class LiveRelayModel: ObservableObject {
    @Published private(set) var status = "尚未準備即時投放探測"
    @Published private(set) var armed = false
    @Published private(set) var active = false
    @Published private(set) var logURL: URL?
    let player = AVPlayer()

    private var gate = LiveRelayCaptureGate()
    private var generation: UInt64 = 0
    private var runID: UUID?
    private var captureID: UUID?
    private var sourceActive = false
    private var sourceReady = false
    private var pickerBusy = false
    private var handle: FileHandle?
    private var currentLogURL: URL?
    private var ownsAudioSession = false
    private var timer: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var videoOutput: AVPlayerItemVideoOutput?
    private var startedUptime = 0.0
    private var lastSnapshotUptime: Double?
    private var decodedObservations = 0
    private var brightnessChanges = 0
    private var lastBrightness: Double?
    private var decodedItemTime: Double?
    private var rowsWritten = 0
    private var bytesWritten = 0
    private var stopping = false
    private var logFailure: String?
    private let timestampFormatter = ISO8601DateFormatter()
    private let maximumDuration: Double = 35 * 60
    private let maximumRows = 2400
    private let maximumBytes = 4 * 1024 * 1024

    init() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.isMuted = true
    }

    /// Call before the user opens the route picker. Never change policy after that selection.
    @discardableResult
    func prepare() -> Bool {
        stop(reason: "rearmed")
        generation &+= 1
        let expectedGeneration = generation
        gate = LiveRelayCaptureGate()
        let newRunID = UUID()
        runID = newRunID
        logURL = nil
        captureID = nil
        sourceActive = false; sourceReady = false; pickerBusy = false
        startedUptime = ProcessInfo.processInfo.systemUptime
        lastSnapshotUptime = nil
        decodedObservations = 0; brightnessChanges = 0
        lastBrightness = nil; decodedItemTime = nil
        rowsWritten = 0; bytesWritten = 0; logFailure = nil
        do {
            let folder = URL.documentsDirectory.appending(path: "LiveRelayDiagnostics")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: newRunID.uuidString).appendingPathExtension("jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw NSError(domain: "ESCast.LiveRelay", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "無法建立即時投放診斷"])
            }
            handle = try FileHandle(forWritingTo: url)
            currentLogURL = url
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, policy: .default,
                                  options: [.mixWithOthers])
            try audio.setActive(true)
            ownsAudioSession = true
            armed = true
            status = "已準備；選擇接收端，再開始螢幕分享。沒有外部影片接收端時只做靜音探測。"
            observeRun(generation: expectedGeneration)
            guard append(event: "prepared") else { return false }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.armed, self.generation == expectedGeneration else { return }
                    self.snapshot()
                }
            }
            return true
        } catch {
            let native = error as NSError
            _ = append(event: "prepare_error", details: ["prepare_error_domain": native.domain,
                "prepare_error_code": native.code, "message": String(error.localizedDescription.prefix(320))])
            stop(reason: "prepare_failed")
            status = "無法準備即時投放探測：\(error.localizedDescription)"
            return false
        }
    }

    func updateCapture(active: Bool, ready: Bool, sessionID: UUID?, pickerBusy: Bool) {
        sourceActive = active; sourceReady = ready
        captureID = sessionID; self.pickerBusy = pickerBusy
        guard armed else { return }
        switch gate.update(active: active, ready: ready, sessionID: sessionID, pickerBusy: pickerBusy) {
        case .wait:
            break
        case .start(let session):
            startConsumer(sessionID: session)
        case .stop(let reason):
            stop(reason: reason)
        }
    }

    func stop(reason: String = "user") {
        guard !stopping, armed || handle != nil || ownsAudioSession || player.currentItem != nil else { return }
        stopping = true
        generation &+= 1
        timer?.invalidate(); timer = nil
        observations.forEach { $0.invalidate() }; observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        player.pause()
        player.isMuted = true
        armed = false; active = false
        var deactivationError = ""
        if ownsAudioSession {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { deactivationError = String(error.localizedDescription.prefix(320)) }
            ownsAudioSession = false
        }
        if handle != nil {
            _ = append(event: "stop", details: ["reason": reason, "audio_deactivation_error": deactivationError])
        }
        if let item = player.currentItem, let videoOutput { item.remove(videoOutput) }
        videoOutput = nil
        player.replaceCurrentItem(with: nil)
        var closed = false
        if let handle {
            do { try handle.synchronize() }
            catch { logFailure = error.localizedDescription }
            do { try handle.close(); closed = true }
            catch { logFailure = error.localizedDescription }
        }
        handle = nil
        logURL = closed ? currentLogURL : nil
        currentLogURL = nil
        gate = LiveRelayCaptureGate()
        status = "即時投放探測已停止（\(reason)）；接收端影像、聲音與同步仍須實測。"
        if let logFailure { status += "\n診斷未完整保存：\(logFailure)" }
        stopping = false
    }

    private func startConsumer(sessionID: UUID) {
        guard armed, !active, sourceActive, sourceReady, captureID == sessionID else { return }
        let expectedGeneration = generation
        let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:8766/live.m3u8")!)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.armed, self.generation == expectedGeneration,
                      self.player.currentItem === item else { return }
                if item.status == .failed {
                    _ = self.append(event: "item_failed")
                    self.stop(reason: "item_failed")
                }
                else { self.refreshStatus() }
            }
        })
        active = true
        guard append(event: "consumer_started") else { return }
        // prepare() configured the audio session before route selection. Do not reset it here.
        player.play()
        refreshStatus()
    }

    private func observeRun(generation expectedGeneration: UInt64) {
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.armed, self.generation == expectedGeneration else { return }
                self.refreshStatus()
                _ = self.append(event: "external_playback_changed")
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.armed, self.generation == expectedGeneration else { return }
                self.refreshStatus()
                _ = self.append(event: "time_control_changed")
            }
        })
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification,
                                                 object: player, queue: .main) { [weak self] notification in
            guard let changedPlayer = notification.object as? AVPlayer else { return }
            let value = notification.userInfo?[AVPlayer.rateDidChangeReasonKey]
            let reasonRaw = (value as? AVPlayer.RateDidChangeReason)?.rawValue ?? (value as? String)
            let reasonNames = [
                AVPlayer.RateDidChangeReason.appBackgrounded.rawValue: "appBackgrounded",
                AVPlayer.RateDidChangeReason.audioSessionInterrupted.rawValue: "audioSessionInterrupted",
                AVPlayer.RateDidChangeReason.setRateCalled.rawValue: "setRateCalled",
                AVPlayer.RateDidChangeReason.setRateFailed.rawValue: "setRateFailed"
            ]
            let reasonName = reasonRaw.flatMap { reasonNames[$0] } ?? (reasonRaw == nil ? "missing" : "unknown")
            // Capture at delivery; the player rate may change before the MainActor log task runs.
            let notificationRate = changedPlayer.rate
            Task { @MainActor in
                guard let self, self.armed, self.generation == expectedGeneration,
                      self.player === changedPlayer else { return }
                _ = self.append(event: "rate_changed", details: [
                    "notification_reason_raw": reasonRaw.map { $0 as Any } ?? NSNull(),
                    "notification_reason_name": reasonName,
                    "notification_player_rate": notificationRate
                ])
            }
        })
        for (name, reason) in [(AVPlayerItem.failedToPlayToEndTimeNotification, "item_failed_to_end"),
                               (AVPlayerItem.didPlayToEndTimeNotification, "live_item_ended")] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let item = notification.object as? AVPlayerItem
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let errorDomain = error?.domain ?? ""
                let errorCode = error?.code ?? 0
                let errorMessage = String((error?.localizedDescription ?? "").prefix(320))
                Task { @MainActor in
                    guard let self, self.armed, self.generation == expectedGeneration,
                          let item, self.player.currentItem === item else { return }
                    _ = self.append(event: "item_notification", details: [
                        "notification_reason": reason, "notification_error_domain": errorDomain,
                        "notification_error_code": errorCode, "notification_error_message": errorMessage
                    ])
                    self.stop(reason: reason)
                }
            })
        }
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                 object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, self.armed, self.generation == expectedGeneration else { return }
                _ = self.append(event: "audio_interruption", details: ["interruption_type": type.map { $0 as Any } ?? NSNull()])
                if type == AVAudioSession.InterruptionType.began.rawValue { self.stop(reason: "audio_interruption") }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                 object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.armed, self.generation == expectedGeneration else { return }
                self.refreshStatus()
                _ = self.append(event: "audio_route_changed", details: ["route_change_reason": reason.map { $0 as Any } ?? NSNull()])
            }
        })
        for (name, event) in [(UIApplication.didEnterBackgroundNotification, "app_background"),
                              (UIApplication.willEnterForegroundNotification, "app_foreground")] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.armed, self.generation == expectedGeneration else { return }
                    _ = self.append(event: event)
                }
            })
        }
    }

    private func refreshStatus() {
        // Only the actual external-video flag permits consumer audio. A port name is insufficient.
        player.isMuted = !player.isExternalPlaybackActive
        guard active else { return }
        let mode = player.isMuted ? "手機靜音探測；尚未確認外部影片接收端" : "已請求外部影音播放；請核對接收端影像與聲音"
        let state: String
        switch player.timeControlStatus {
        case .playing: state = "（播放中）"
        case .waitingToPlayAtSpecifiedRate: state = "（載入或緩衝中）"
        case .paused: state = "（播放器已暫停；未自動恢復）"
        @unknown default: state = "（播放狀態未確認）"
        }
        status = mode + state
    }

    private func snapshot() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - startedUptime < maximumDuration else { stop(reason: "duration_limit"); return }
        refreshStatus()
        observeDecodedPixels()
        let gap: Any = lastSnapshotUptime.map { (now - $0) as Any } ?? NSNull()
        lastSnapshotUptime = now
        _ = append(event: "sample", details: ["snapshot_gap_seconds": gap])
    }

    private func observeDecodedPixels() {
        guard active, let videoOutput, player.currentItem != nil else { return }
        let requestedTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard requestedTime.isNumeric, videoOutput.hasNewPixelBuffer(forItemTime: requestedTime) else { return }
        var displayTime = CMTime.invalid
        guard let pixel = videoOutput.copyPixelBuffer(forItemTime: requestedTime,
                                                       itemTimeForDisplay: &displayTime) else { return }
        decodedObservations += 1
        if displayTime.isNumeric { decodedItemTime = CMTimeGetSeconds(displayTime) }
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard width > 0, height > 0 else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for row in 0..<16 {
            for column in 0..<16 {
                let offset = min(height - 1, row * height / 16) * stride + min(width - 1, column * width / 16) * 4
                sum += 0.0722 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.2126 * Double(bytes[offset + 2])
            }
        }
        let brightness = sum / (256 * 255)
        if let lastBrightness, abs(brightness - lastBrightness) >= 0.03 { brightnessChanges += 1 }
        lastBrightness = brightness
    }

    @discardableResult
    private func append(event: String, details: [String: Any] = [:]) -> Bool {
        guard let handle else { return false }
        let audio = AVAudioSession.sharedInstance()
        let item = player.currentItem
        let itemError = item?.error as NSError?
        let itemSeconds = CMTimeGetSeconds(player.currentTime())
        var row: [String: Any] = [
            "event": event, "observed_at": timestampFormatter.string(from: Date()),
            "uptime_seconds": ProcessInfo.processInfo.systemUptime,
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - startedUptime,
            "relay_session_uuid": runID?.uuidString ?? "", "generation": generation,
            "capture_session_uuid": captureID.map { $0.uuidString as Any } ?? NSNull(),
            "bound_capture_session_uuid": gate.sessionID.map { $0.uuidString as Any } ?? NSNull(),
            "source_active": sourceActive, "source_ready": sourceReady, "picker_busy": pickerBusy,
            "armed": armed, "consumer_requested": active,
            "app_state": UIApplication.shared.applicationState.rawValue,
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
            "item_status": item?.status.rawValue ?? -1, "time_control_status": player.timeControlStatus.rawValue,
            "player_rate": player.rate, "player_time_seconds": itemSeconds.isFinite ? itemSeconds : NSNull(),
            "waiting_reason": player.reasonForWaitingToPlay?.rawValue ?? "",
            "external_playback_active": player.isExternalPlaybackActive, "consumer_muted": player.isMuted,
            "consumer_audio_mode": player.isMuted ? "muted_phone_probe" : "external_audio_requested",
            "audio_category": audio.category.rawValue, "audio_mode": audio.mode.rawValue,
            "route_sharing_policy": audio.routeSharingPolicy.rawValue,
            "background_playback_policy": player.audiovisualBackgroundPlaybackPolicy.rawValue,
            "category_options": audio.categoryOptions.rawValue,
            "audio_output_port_types": audio.currentRoute.outputs.map { $0.portType.rawValue },
            "decoded_pixel_observations": decodedObservations, "decoded_brightness_changes": brightnessChanges,
            "decoded_item_time_seconds": decodedItemTime.map { $0 as Any } ?? NSNull(),
            "decoded_mean_brightness": lastBrightness.map { $0 as Any } ?? NSNull(),
            "error_domain": itemError?.domain ?? "", "error_code": itemError?.code ?? 0,
            "error_message": String((itemError?.localizedDescription ?? "").prefix(320)),
            "vehicle_playback_verified": false, "vehicle_av_sync_verified": false,
            "audible_output_verified": false, "feedback_exclusion_verified": false
        ]
        row.merge(details) { _, new in new }
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0A)
            // Reserve one row and 4 KiB for the terminal reason if a run reaches its bound.
            let rowLimit = stopping ? maximumRows : maximumRows - 1
            let byteLimit = stopping ? maximumBytes : maximumBytes - 4096
            guard rowsWritten < rowLimit, bytesWritten + data.count <= byteLimit else {
                if !stopping { stop(reason: "diagnostic_limit") }
                return false
            }
            try handle.write(contentsOf: data)
            rowsWritten += 1; bytesWritten += data.count
            return true
        } catch {
            logFailure = error.localizedDescription
            if !stopping { stop(reason: "diagnostic_write_failed") }
            return false
        }
    }

    deinit {
        timer?.invalidate()
        observations.forEach { $0.invalidate() }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? handle?.close()
    }
}
