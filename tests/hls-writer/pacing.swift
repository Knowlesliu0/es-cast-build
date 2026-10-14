import Foundation
import AVFoundation

private func jitteredThirtyFPS(_ sample: CMSampleBuffer, index: Int) throws -> CMSampleBuffer? {
    // Derive a 30fps source from the 60fps fixture, with sub-millisecond capture jitter.
    guard index.isMultiple(of: 2) else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    try check(CMSampleBufferGetNumSamples(sample) == 1 &&
              CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              "fixture must supply a single video sample")
    let frame = index / 2
    let shift = CMTime(value: frame % 3 == 1 ? 36 : frame % 3 == 2 ? -36 : 0, timescale: 60000)
    timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, shift)
    if timing.decodeTimeStamp.isNumeric { timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, shift) }
    var result: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &result)
    try check(status == noErr && result != nil, "fixture timestamp jitter failed")
    return result
}

func verifyJitteredPacing() async throws {
    let store = HLSStore(windowSize: 12)
    let queue = DispatchQueue(label: "tw.escast.jitter-test")
    let writer = LiveHLSWriter(store: store, queue: queue)
    queue.sync { writer.startMonitoring() }
    _ = try await feedFixture(writer, queue: queue, videoTransform: jitteredThirtyFPS)
    try await writer.finish()
    let accepted = writer.diagnostic()["video_samples"] as? Int ?? 0
    try check(accepted == 360, "sub-millisecond jitter discarded source frames: \(accepted)/360")
    try store.export(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-jittered", isDirectory: true))
}
