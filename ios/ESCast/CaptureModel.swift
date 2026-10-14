import SwiftUI
import ScreenCaptureKit
import AVFoundation

@MainActor
final class CaptureModel: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未開始擷取"
    @Published private(set) var summary = "尚無樣本"
    @Published private(set) var logURL: URL?
    @Published private(set) var recordingURL: URL?
    @Published var saveRecording = false
    @Published var liveStreaming = true
    @Published private(set) var liveReady = false
    @Published private(set) var liveSessionID: UUID?
    @Published private(set) var liveStatus = "尚未啟動本機串流"
    let playlistURL = URL(string: "http://127.0.0.1:8766/playlist.m3u")!

    private var stream: SCStream?
    private var telemetry: CaptureTelemetry?
    private var recording: SCRecordingOutput?
    private var recordingDelegate: RecordingDelegate?
    private var pendingRecordingURL: URL?
    private var picker = SCContentSharingPicker.shared
    private var observerRegistered = false
    private var stopping = false
    private var liveWriter: LiveHLSWriter?
    private var liveServer: LocalHLSServer?
    private var sessionFolder: URL?
#if SOURCE_RECOVERY_OBSERVATION
    private var recoveryCoordinator: SourceRecoveryCoordinator?
#endif

    func chooseScreen() {
        guard !busy, !active else { return }
        guard picker.isAvailable else { status = "此裝置目前無法使用系統螢幕分享"; return }
        busy = true
        status = "請在系統視窗同意分享整個螢幕"
        if !observerRegistered { picker.add(self); observerRegistered = true }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present() // Full display, not presentForCurrentApplication().
    }

    private func start(filter: SCContentFilter) async {
        guard stream == nil, !stopping, busy, observerRegistered else { return }
        do {
            let folder = URL.documentsDirectory.appending(path: "Sessions/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            sessionFolder = folder
            liveSessionID = UUID(uuidString: folder.lastPathComponent)
            liveReady = false
            let logger = try CaptureTelemetry(url: folder.appending(path: "capture.jsonl"))
            logger.onSummary = { [weak self, weak logger] text in Task { @MainActor in
                guard let self, let logger, self.telemetry === logger else { return }
                self.summary = text
            } }
            logger.onFailure = { [weak self, weak logger] error in
                Task { @MainActor in
                    guard let self, let logger, self.telemetry === logger else { return }
                    await self.stop(reason: "log_error", detail: error)
                }
            }
            telemetry = logger
            logURL = nil
            recordingURL = nil
            pendingRecordingURL = nil
            let config = SCStreamConfiguration()
            config.width = 720
            config.height = 1280
            // Frame cadence and queue configuration are managed by iOS.
            // Their macOS setters are explicitly unavailable in the iOS 27 SDK.
            config.capturesAudio = true
            // Microphone capture is disabled in the picker; no microphone output is attached.
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            stream = capture
            try capture.addStreamOutput(logger, type: .screen, sampleHandlerQueue: logger.queue)
            try capture.addStreamOutput(logger, type: .audio, sampleHandlerQueue: logger.queue)
            if saveRecording {
                let destination = folder.appending(path: "capture.mp4")
                let recordingConfig = SCRecordingOutputConfiguration()
                recordingConfig.outputURL = destination
                recordingConfig.outputFileType = .mp4
                recordingConfig.videoCodecType = .h264
                let delegate = RecordingDelegate()
                delegate.onFailure = { [weak self, weak delegate] error in
                    Task { @MainActor in
                        guard let self, let delegate, self.recordingDelegate === delegate else { return }
                        await self.stop(reason: "recording_error", detail: error)
                    }
                }
                let output = SCRecordingOutput(configuration: recordingConfig, delegate: delegate)
                try capture.addRecordingOutput(output)
                recordingDelegate = delegate
                recording = output
                pendingRecordingURL = destination
            }
            if liveStreaming {
                liveStatus = "正在啟動本機串流…"
                let store = HLSStore()
                let encoder = LiveHLSWriter(store: store, queue: logger.queue)
                encoder.onSummary = { [weak self, weak encoder] text in
                    Task { @MainActor in
                        guard let self, let encoder, self.liveWriter === encoder, !self.stopping else { return }
#if SOURCE_RECOVERY_OBSERVATION
                        guard self.recoveryCoordinator == nil else { return }
#endif
                        self.liveStatus = text
                        self.liveReady = encoder.store.ready
                    }
                }
                encoder.onFailure = { [weak self, weak encoder] error in
                    Task { @MainActor in
                        guard let self, let encoder, self.liveWriter === encoder else { return }
#if SOURCE_RECOVERY_OBSERVATION
                        if await self.observeSourceFailure(error as NSError, encoder: encoder) { return }
#endif
                        await self.stop(reason: "encoder_error", detail: error)
                    }
                }
                // The writer reports failures once through onFailure; no raw-buffer async backlog.
                logger.onMediaSample = { [weak encoder] sample, type in try? encoder?.append(sample, type: type) }
                liveWriter = encoder
                let server = LocalHLSServer(store: store)
                server.onFailure = { [weak self, weak server] error in
                    Task { @MainActor in
                        guard let self, let server, self.liveServer === server else { return }
                        await self.stop(reason: "http_error", detail: error)
                    }
                }
                liveServer = server
                try await server.start()
                guard !stopping, stream === capture else { server.stop(); return }
                liveStatus = "正在準備串流，約十秒後可讀取…"
            } else { liveStatus = "僅擷取測試，未啟動串流" }
            logger.begin()
            try await capture.startCapture()
            guard !stopping, stream === capture else { return }
            if let encoder = liveWriter { logger.queue.async { encoder.startMonitoring() } }
            active = true
            busy = false
            status = "擷取已開始；請收起分享提示窗，再切到紅果播放。"
        } catch {
            await stop(reason: "start_error", detail: error)
        }
    }

#if SOURCE_RECOVERY_OBSERVATION
    private func observeSourceFailure(_ error: NSError, encoder: LiveHLSWriter) async -> Bool {
        guard !stopping, recoveryCoordinator == nil, let logger = telemetry,
              let folder = sessionFolder, let sessionID = UUID(uuidString: folder.lastPathComponent),
              error.domain == "ESCast.HLS", error.code == 12,
              let failureUptime = error.userInfo["source_failure_uptime_seconds"] as? Double else { return false }
        let observation = SourceRecoveryCoordinator(sessionID: sessionID)
        recoveryCoordinator = observation
        let began = observation.begin(error: error, failureUptime: failureUptime, stopStreaming: {
            self.liveReady = false
            self.liveServer?.stop()
            self.liveStatus = "串流已停止，正在觀察來源，最多 15 秒"
            self.status = "來源中斷：\(error.localizedDescription)\n觀察結束後會保存診斷；也可手動停止。"
        }, finishEncoder: {
            do { try await encoder.finish(); return .success(()) }
            catch { return .failure(error) }
        }, expired: { [weak self, weak observation] expiredSession in
            guard let self, let observation, self.recoveryCoordinator === observation,
                  self.sessionFolder == folder, expiredSession == sessionID else { return }
            await self.stop(reason: "recovery_window_ended")
        })
        guard began, let deadline = observation.deadline else { recoveryCoordinator = nil; return false }
        logger.onRecoveryDeadline = { [weak self, weak observation] in
            Task { @MainActor in
                guard let self, let observation, self.recoveryCoordinator === observation,
                      self.sessionFolder == folder else { return }
                await self.stop(reason: "recovery_window_ended")
            }
        }
        logger.onValidVideoRecovered = { [weak self, weak observation] in
            Task { @MainActor in
                guard let self, let observation, self.recoveryCoordinator === observation,
                      !self.stopping else { return }
                self.liveStatus = "曾觀察到來源恢復；串流仍已停止，等待觀察結束"
            }
        }
        do { try logger.beginSourceRecoveryObservation(sessionID: sessionID, failure: error, deadline: deadline) }
        catch { await stop(reason: "log_error", detail: error) }
        return true
    }
#endif

    func stop(reason: String = "user", detail: Error? = nil,
              streamAlreadyStopped: Bool = false, reportedStreamError: Error? = nil) async {
        guard !stopping else { return }
        stopping = true
        busy = true
        liveReady = false
        status = "正在停止並保存測試紀錄…"
        var failure = detail
        var reported = reportedStreamError
#if SOURCE_RECOVERY_OBSERVATION
        let observation = recoveryCoordinator
        observation?.close()
        failure = observation?.firstError ?? detail
        var diagnosticSaveError: String?
        do {
            try telemetry?.endSourceRecoveryObservation(reason: reason, secondaryError: detail ?? reportedStreamError)
        } catch { diagnosticSaveError = error.localizedDescription; failure = failure ?? error }
#endif
        if let stream, !streamAlreadyStopped {
            do { try await stream.stopCapture() }
            catch {
                failure = failure ?? CaptureTermination.failure(for: error)
                reported = reported ?? error
            }
        }
        // End sample-delivery measurement before waiting for MP4 finalization.
        // Encoder drain time is not a capture dropout.
        let finalReason = failure == nil ? (reason == "system_user" ? "user" : reason) : "error"
        telemetry?.finish(reason: finalReason, requestedReason: reason, error: failure,
                          reportedStreamError: reported)
        logURL = telemetry?.url
        telemetry = nil
        if let encoder = liveWriter {
            do {
#if SOURCE_RECOVERY_OBSERVATION
                if let observation, let result = await observation.waitForEncoder() { try result.get() }
                else { try await encoder.finish() }
#else
                try await encoder.finish()
#endif
                if saveRecording, let sessionFolder {
                    try encoder.store.export(to: sessionFolder.appending(path: "HLS"))
                }
            } catch { failure = failure ?? error }
            if let sessionFolder {
                do {
                    let data = try JSONSerialization.data(withJSONObject: encoder.diagnostic(), options: [.sortedKeys, .prettyPrinted])
                    try data.write(to: sessionFolder.appending(path: "hls-status.json"), options: .atomic)
                } catch { failure = failure ?? error }
            }
        }
        liveServer?.stop()
        if let server = liveServer, let sessionFolder {
            do {
                let data = try JSONSerialization.data(withJSONObject: server.diagnostic(), options: [.sortedKeys, .prettyPrinted])
                try data.write(to: sessionFolder.appending(path: "hls-http.json"), options: .atomic)
            } catch { failure = failure ?? error }
        }
        liveServer = nil; liveWriter = nil; sessionFolder = nil
        liveSessionID = nil
        liveReady = false
        liveStatus = "本機串流已停止"
        // The system finalizes SCRecordingOutput when capture stops. Do not expose an unfinished file.
        if let delegate = recordingDelegate {
            let result = await delegate.waitForCompletion()
            switch result {
            case .success:
                if failure == nil { recordingURL = pendingRecordingURL }
            case .failure(let error):
                failure = failure ?? error
            }
        }
        stream = nil
        recording = nil
        recordingDelegate = nil
        pendingRecordingURL = nil
#if SOURCE_RECOVERY_OBSERVATION
        recoveryCoordinator = nil
#endif
        picker.isActive = false
        if observerRegistered { picker.remove(self); observerRegistered = false }
        active = false
        busy = false
        stopping = false
        status = failure.map {
            let native = $0 as NSError
            return "測試未完成：\(native.localizedDescription)\n\(native.domain)（\(native.code)）"
        } ?? "已停止並保存紀錄；車機與同步仍須實測。"
#if SOURCE_RECOVERY_OBSERVATION
        if let diagnosticSaveError { status += "\n來源觀察紀錄未完整保存：\(diagnosticSaveError)" }
#endif
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            // This probe opens the full-display picker only before starting a session.
            // updateContentFilter is unavailable on iOS; a new session needs a new stream.
            guard stream == nil, self.stream == nil else { return }
            await self.start(filter: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            if self.stream == nil {
                self.busy = false
                self.picker.isActive = false
                if self.observerRegistered { self.picker.remove(self); self.observerRegistered = false }
                self.status = "已取消螢幕分享"
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in await self.stop(reason: "picker_error", detail: error) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            let failure = CaptureTermination.failure(for: error)
            await self.stop(reason: failure == nil ? "system_user" : "stream_error", detail: failure,
                            streamAlreadyStopped: true, reportedStreamError: error)
        }
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: Result<Void, Error>?
    var onFailure: ((Error) -> Void)?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); completion = .success(()); lock.unlock()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); completion = .failure(error); lock.unlock()
        onFailure?(error)
    }

    private func currentResult() -> Result<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        return completion
    }

    func waitForCompletion() async -> Result<Void, Error> {
        for _ in 0..<200 {
            if let result = currentResult() { return result }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return .failure(error) }
        }
        return .failure(NSError(domain: "ESCast", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "錄影檔尚未完成，不能視為可用成果"]))
    }
}
