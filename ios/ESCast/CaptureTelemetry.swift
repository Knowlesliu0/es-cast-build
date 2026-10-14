import Foundation
import CoreMedia
import ScreenCaptureKit
import AVFoundation

/// Only counters and timestamps are retained. This does not measure vehicle A/V sync.
final class CaptureTelemetry: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "tw.escast.samples")
    let url: URL
    private let handle: FileHandle
    private var timer: DispatchSourceTimer?
    private var started = ProcessInfo.processInfo.systemUptime
    private var videoFrames = 0
    private var audioBuffers = 0
    private var lastVideo: Double?
    private var lastAudio: Double?
    private var screenCallbacks = 0
    private var screenStatusCounts: [String: Int] = [:]
    private var lastScreenCallback: Double?
    private var screenInvalidBuffers = 0
    private var screenUnreadyBuffers = 0
    private var closed = false
    var onSummary: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onMediaSample: ((CMSampleBuffer, AVMediaType) -> Void)?
#if SOURCE_RECOVERY_OBSERVATION
    private var recovery: [String: Any]?
    private var recoveryDeadline: Double?
    private var recoveryEnded = false
    private var recoveryDeadlineSent = false
    var onRecoveryDeadline: (() -> Void)?
    var onValidVideoRecovered: (() -> Void)?

    /// 呼叫者不在 capture queue；卸下 encoder 與診斷寫入在同一 queue 原子排序。
    func beginSourceRecoveryObservation(sessionID: UUID, failure: NSError, deadline: Double) throws {
        try queue.sync {
            onMediaSample = nil
            guard !closed, recovery == nil else { throw NSError(domain: "ESCast.Recovery", code: 1) }
            let now = ProcessInfo.processInfo.systemUptime
            recoveryDeadline = deadline
            recovery = ["session_id": sessionID.uuidString,
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "first_error_domain": failure.domain, "first_error_code": failure.code,
                "first_error_message": failure.localizedDescription,
                "failure_details": failure.userInfo,
                "failure_uptime": deadline - 15, "observation_started_uptime": now,
                "deadline_uptime": deadline,
                "first_callback_uptime": NSNull(), "first_valid_video_uptime": NSNull(),
                "http_stopped_during_observation": true, "streaming_recovered": false,
                "last_callback_before_observation": lastScreenCallback.map { $0 as Any } ?? NSNull(),
                "last_video_before_observation": lastVideo.map { $0 as Any } ?? NSNull()]
            write(["event": "source_timeout", "elapsed": now - started, "diagnostic": recovery!])
            try persistRecovery()
        }
    }

    func endSourceRecoveryObservation(reason: String, secondaryError: Error?) throws {
        try queue.sync {
            guard recovery != nil, !recoveryEnded else { return }
            recoveryEnded = true
            let now = ProcessInfo.processInfo.systemUptime
            recovery?["end_reason"] = reason
            recovery?["end_requested_uptime"] = now
            recovery?["deadline_overrun_seconds"] = max(0, now - (recoveryDeadline ?? now))
            if let error = secondaryError as NSError? {
                recovery?["secondary_error_domain"] = error.domain
                recovery?["secondary_error_code"] = error.code
                recovery?["secondary_error_message"] = error.localizedDescription
            }
            write(["event": "observation_end", "elapsed": now - started, "diagnostic": recovery!])
            try persistRecovery()
        }
    }

    private func persistRecovery() throws {
        guard !closed, let recovery else { throw NSError(domain: "ESCast.Recovery", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "來源觀察紀錄未能完整保存"]) }
        try handle.synchronize()
        let data = try JSONSerialization.data(withJSONObject: recovery, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url.deletingLastPathComponent().appending(path: "source-recovery.json"), options: .atomic)
    }

    private func checkRecoveryDeadline(now: Double) {
        guard !recoveryEnded, !recoveryDeadlineSent, let deadline = recoveryDeadline,
              now >= deadline else { return }
        recoveryDeadlineSent = true
        onRecoveryDeadline?()
    }

    private func observeRecovery(validVideo: Bool, sample: CMSampleBuffer, now: Double) {
        guard !recoveryEnded, let deadline = recoveryDeadline, now < deadline else { return }
        let key = validVideo ? "first_valid_video_uptime" : "first_callback_uptime"
        guard recovery?[key] is NSNull else { return }
        recovery?[key] = now
        let prior = validVideo ? lastVideo : lastScreenCallback
        var row: [String: Any] = ["event": validVideo ? "first_valid_video_recovered" : "first_callback_recovered",
            "elapsed": now - started, "uptime": now, "streaming_recovered": false]
        if let prior { row["gap_seconds"] = now - prior }
        if sample.isValid {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isNumeric { row["source_pts"] = CMTimeGetSeconds(pts) }
        }
        recovery?[validVideo ? "valid_video_recovery" : "callback_recovery"] = row
        write(row)
        do {
            try persistRecovery()
            if validVideo { onValidVideoRecovered?() }
        } catch { onFailure?(error) }
    }
#endif

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "ESCast", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "無法建立測試紀錄"])
        }
        handle = try FileHandle(forWritingTo: url)
        super.init()
    }

    func begin() {
        queue.sync {
            started = ProcessInfo.processInfo.systemUptime
            write(["event": "start", "elapsed": 0,
                   "screen_status_codes": ["complete": SCFrameStatus.complete.rawValue,
                                           "idle": SCFrameStatus.idle.rawValue,
                                           "blank": SCFrameStatus.blank.rawValue,
                                           "started": SCFrameStatus.started.rawValue,
                                           "suspended": SCFrameStatus.suspended.rawValue,
                                           "stopped": SCFrameStatus.stopped.rawValue]])
            guard !closed else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler { [weak self] in self?.snapshot() }
            timer = source
            source.resume()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // ScreenCaptureKit invokes this on `queue`, configured by CaptureModel.
        consume(sampleBuffer, type: type)
    }

    /// 與 SCStream 回呼共用的處理入口；呼叫端必須在 queue 上。
    func consume(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard !closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
#if SOURCE_RECOVERY_OBSERVATION
        checkRecoveryDeadline(now: now)
#endif
        var screenStatus: Int?
        if type == .screen {
#if SOURCE_RECOVERY_OBSERVATION
            observeRecovery(validVideo: false, sample: sampleBuffer, now: now)
#endif
            screenCallbacks += 1
            lastScreenCallback = now
            if sampleBuffer.isValid {
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]]
                screenStatus = attachments?.first?[.status] as? Int
                if !CMSampleBufferDataIsReady(sampleBuffer) { screenUnreadyBuffers += 1 }
            } else {
                screenInvalidBuffers += 1
            }
            screenStatusCounts[screenStatus.map { String($0) } ?? "unknown", default: 0] += 1
        }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            // Idle/incomplete frames must not reset the video watchdog.
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
                  let status = screenStatus,
                  SCFrameStatus(rawValue: status) == .complete else { return }
#if SOURCE_RECOVERY_OBSERVATION
            observeRecovery(validVideo: true, sample: sampleBuffer, now: now)
#endif
            videoFrames += 1
            lastVideo = now
            onMediaSample?(sampleBuffer, .video)
        case .audio:
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
            audioBuffers += 1
            lastAudio = now
            onMediaSample?(sampleBuffer, .audio)
        default:
            break // Microphone is not requested or used.
        }
    }

    private func snapshot() {
        let now = ProcessInfo.processInfo.systemUptime
#if SOURCE_RECOVERY_OBSERVATION
        checkRecoveryDeadline(now: now)
#endif
        var row: [String: Any] = ["event": "sample", "elapsed": now - started,
                                  "video_frames": videoFrames, "audio_buffers": audioBuffers,
                                  "screen_callbacks": screenCallbacks,
                                  "screen_status_counts": screenStatusCounts,
                                  "screen_invalid_buffers": screenInvalidBuffers,
                                  "screen_unready_buffers": screenUnreadyBuffers]
        if let lastScreenCallback { row["screen_callback_age"] = now - lastScreenCallback }
        else { row["screen_callback_age"] = NSNull() }
        if let lastVideo { row["video_age"] = now - lastVideo }
        else { row["video_age"] = NSNull() }
        if let lastAudio { row["audio_age"] = now - lastAudio }
        else { row["audio_age"] = NSNull() }
        write(row)
        let staleVideo = lastVideo.map { now - $0 > 2 } ?? true
        let staleAudio = lastAudio.map { now - $0 > 2 } ?? true
        onSummary?("\(Int(now - started)) 秒 · 影像 \(videoFrames) · 音訊 \(audioBuffers)"
                   + ((staleVideo || staleAudio) ? "\n部分樣本未更新，請檢查紀錄" : ""))
    }

    func finish(reason: String, requestedReason: String, error: Error?, reportedStreamError: Error? = nil) {
        queue.sync {
            guard !closed else { return }
            timer?.cancel()
            timer = nil
            snapshot()
            var row: [String: Any] = ["event": "stop", "elapsed": ProcessInfo.processInfo.systemUptime - started,
                                      "reason": reason, "requested_reason": requestedReason]
            if let error {
                let native = error as NSError
                row["error_domain"] = native.domain
                row["error_code"] = native.code
                row["error_message"] = native.localizedDescription
            }
            if let reportedStreamError {
                let native = reportedStreamError as NSError
                row["reported_stream_error_domain"] = native.domain
                row["reported_stream_error_code"] = native.code
                row["reported_stream_error_message"] = native.localizedDescription
            }
            write(row)
            closed = true
            do { try handle.synchronize(); try handle.close() }
            catch { onFailure?(error) }
        }
    }

    private func write(_ row: [String: Any]) {
        guard !closed else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            closed = true
            timer?.cancel()
            timer = nil
            try? handle.close()
            onFailure?(error)
        }
    }
}
