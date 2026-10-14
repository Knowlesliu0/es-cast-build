import Foundation
import AVFoundation

/// Missing screen updates must not erase the original timeline when updates resume.
/// This simulates a capture gap, not proof that an unchanged screen is healthy.
func verifySparseVideoRecovery(realTime: Bool = false) async throws {
    let store = HLSStore(windowSize: 12, retentionSize: 16)
    let queue = DispatchQueue(label: "tw.escast.sparse-video-test")
    let writer = LiveHLSWriter(store: store, queue: queue)
    var omitted = 0
    var monitoring = false
    var gapStartSegments: Int?
    var checkedLiveGap = false
    do {
        // Offline input: isolate the cross-track PTS guard from wall-clock arrival tests.
        _ = try await feedFixture(writer, queue: queue, realTime: realTime) { sample, _ in
            if realTime && !monitoring {
                queue.sync { writer.startMonitoring() }
                monitoring = true
            }
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if seconds >= 3 && seconds < 6 {
                if gapStartSegments == nil { gapStartSegments = store.producedSegmentCount }
                if realTime && seconds >= 5.9 && !checkedLiveGap {
                    try check(store.producedSegmentCount > gapStartSegments!,
                              "no new finalized segment while source images were absent")
                    try check(writer.diagnostic()["source_video_state"] as? String == "no_recent_source_image",
                              "held frames falsely reported a recovered source")
                    checkedLiveGap = true
                }
                omitted += 1
                return nil
            }
            return sample
        }
        let active = writer.diagnostic()
        try check(!realTime || checkedLiveGap, "live gap was not observed")
        try check((active["held_video_frames"] as? Int ?? 0) > 0,
                  "missing held frames during sparse input")
        try check(active["encoded_source_video_frames"] as? Int == 270,
                  "held images replaced or inflated the encoded source count: \(active)")
        try check(active["retained_source_images"] as? Int == 1,
                  "sparse writer must retain exactly one source image")
        try check(active["source_video_state"] as? String == "receiving",
                  "source state did not recover after new images returned")
        try check(abs((active["last_source_video_pts"] as? Double ?? -1) - 719.0 / 60.0) < 0.001,
                  "source input did not resume at original timestamps (output checked separately)")
        try await writer.finish()
        try check(writer.diagnostic()["retained_source_images"] as? Int == 0,
                  "finish retained the source image")
        try check(omitted == 180, "fixture did not omit exactly three seconds of video")
        try check(store.ready && store.producedSegmentCount >= 5,
                  "sparse source did not produce a usable finalized playlist")
        let suffix = realTime ? "-sparse-live" : "-sparse"
        try store.export(to: URL(fileURLWithPath: CommandLine.arguments[2] + suffix, isDirectory: true))
    } catch {
        try? await writer.finish()
        let detail = error as NSError
        print("Sparse failure domain=\(detail.domain) code=\(detail.code) details=\(detail.userInfo)")
        throw error
    }
}

/// The final source update is white, but falls inside the previous frame's 30 Hz slot.
/// All subsequent source video is absent. Decode the exported result to verify white wins.
func verifyLatestPacedSourceImage() async throws {
    let store = HLSStore(windowSize: 12, retentionSize: 16)
    let queue = DispatchQueue(label: "tw.escast.last-image-test")
    let writer = LiveHLSWriter(store: store, queue: queue)
    do {
        _ = try await feedFixture(writer, queue: queue) { sample, index in
            if index > 120 { return nil }
            if index != 120 { return sample }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                presentationTimeStamp: CMTime(value: 199, timescale: 100), decodeTimeStamp: .invalid)
            var result: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &result)
            try check(status == noErr && result != nil, "could not prepare final source image")
            return result
        }
        try await writer.finish()
        try store.export(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-last-image", isDirectory: true))
    } catch {
        try? await writer.finish()
        throw error
    }
}
