import Foundation
import AVFoundation
import ScreenCaptureKit

private struct TelemetryCheckFailure: Error { let message: String }
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw TelemetryCheckFailure(message: "Expected non-nil value") }
    return value
}
private func checkEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
    guard actual == expected else {
        throw TelemetryCheckFailure(message: "Expected \(expected), got \(actual)")
    }
}

final class SourceRecoveryTelemetryTests {
    private func frame(status: SCFrameStatus) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        try checkEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let image = try require(pixel)
        var format: CMVideoFormatDescription?
        try checkEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                                   formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: CMTime(value: 10, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try checkEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: try require(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let result = try require(sample)
        let attachments = try require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        entry[SCStreamFrameInfo.status.rawValue] = status.rawValue
        return result
    }

    func testRecoverySeparatesRawCallbackFromValidVideoAndDetachesWriter() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logger = try CaptureTelemetry(url: folder.appending(path: "capture.jsonl"))
        var forwarded = 0
        logger.onMediaSample = { _, _ in forwarded += 1 }
        logger.begin()
        let failure = NSError(domain: "ESCast.HLS", code: 12,
            userInfo: ["timeout_trigger": "test", "source_failure_uptime_seconds": ProcessInfo.processInfo.systemUptime])
        try logger.beginSourceRecoveryObservation(sessionID: UUID(), failure: failure,
                                                   deadline: ProcessInfo.processInfo.systemUptime + 15)
        let idle = try frame(status: .idle), complete = try frame(status: .complete)
        logger.queue.sync { logger.consume(idle, type: .screen) }
        func diagnostic() throws -> [String: Any] {
            try require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "source-recovery.json"))) as? [String: Any])
        }
        let partial = try diagnostic()
        _ = try require(partial["first_callback_uptime"] as? Double)
        try checkEqual(partial["first_valid_video_uptime"] is NSNull, true)
        logger.queue.sync { logger.consume(complete, type: .screen); logger.consume(complete, type: .screen) }
        try logger.endSourceRecoveryObservation(reason: "user", secondaryError: nil)
        logger.finish(reason: "error", requestedReason: "user", error: failure)
        let saved = try diagnostic()
        _ = try require(saved["first_valid_video_uptime"] as? Double)
        try checkEqual(saved["streaming_recovered"] as? Bool, false)
        try checkEqual(saved["http_stopped_during_observation"] as? Bool, true)
        try checkEqual(forwarded, 0)
        let rows = try String(contentsOf: logger.url, encoding: .utf8).split(separator: "\n").map {
            try require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        try checkEqual(rows.filter { $0["event"] as? String == "first_callback_recovered" }.count, 1)
        try checkEqual(rows.filter { $0["event"] as? String == "first_valid_video_recovered" }.count, 1)
        try checkEqual(rows.filter { $0["event"] as? String == "observation_end" }.count, 1)
    }
}
