import Foundation
import AVFoundation
import CoreVideo

struct IntegrationFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw IntegrationFailure(message: message) }
}

func feedFixture(_ writer: LiveHLSWriter, queue: DispatchQueue,
                 realTime: Bool = false,
                 videoTransform: ((CMSampleBuffer, Int) throws -> CMSampleBuffer?)? = nil) async throws -> (Int, Int) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
        throw IntegrationFailure(message: "source tracks missing")
    }
    let reader = try AVAssetReader(asset: asset)
    let video = AVAssetReaderTrackOutput(track: videoTrack,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    let audio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
    video.alwaysCopiesSampleData = false; audio.alwaysCopiesSampleData = false
    reader.add(video); reader.add(audio)
    try check(reader.startReading(), "reader did not start")
    var nextVideo = video.copyNextSampleBuffer()
    var nextAudio = audio.copyNextSampleBuffer()
    var videoCount = 0, audioCount = 0
    let wallStart = ProcessInfo.processInfo.systemUptime
    var sourceStart: Double?
    while nextVideo != nil || nextAudio != nil {
        let useVideo = nextVideo != nil && (nextAudio == nil ||
            CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(nextVideo!),
                          CMSampleBufferGetPresentationTimeStamp(nextAudio!)) <= 0)
        let type: AVMediaType = useVideo ? .video : .audio
        let original = useVideo ? nextVideo! : nextAudio!
        if realTime {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(original))
            if sourceStart == nil { sourceStart = pts }
            let remaining = pts - sourceStart! - (ProcessInfo.processInfo.systemUptime - wallStart)
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        let transformed: CMSampleBuffer?
        if useVideo, let videoTransform { transformed = try videoTransform(original, videoCount) }
        else { transformed = original }
        if let sample = transformed {
            var attempts = 0
            while !queue.sync(execute: { writer.isReadyFor(type) }) {
                try await Task.sleep(nanoseconds: 1_000_000)
                attempts += 1
                if attempts > 5000 { throw IntegrationFailure(message: "encoder readiness timeout") }
            }
            try queue.sync { try writer.append(sample, type: type) }
        }
        if useVideo { videoCount += 1; nextVideo = video.copyNextSampleBuffer() }
        else { audioCount += 1; nextAudio = audio.copyNextSampleBuffer() }
    }
    try check(reader.status == .completed, "reader did not complete")
    return (videoCount, audioCount)
}

func encodeFixture() async throws {
    let store = HLSStore(windowSize: 12, retentionSize: 16)
    let queue = DispatchQueue(label: "tw.escast.writer-test")
    let writer = LiveHLSWriter(store: store, queue: queue)
    queue.sync { writer.startMonitoring() }
    let (videoCount, audioCount) = try await feedFixture(writer, queue: queue)
    try await writer.finish()
    try check(store.producedSegmentCount >= 5 && store.ready, "finalized fragments missing")
    try store.export(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    print("Encoded source buffers video=\(videoCount) audio=\(audioCount) fragments=\(store.producedSegmentCount)")
}

func verifyHTTP() async throws {
    let store = HLSStore()
    try store.setInitialization(Data("test-init".utf8))
    for _ in 0..<6 { try store.append(Data("test-fragment".utf8), duration: 2) }
    let server = LocalHLSServer(store: store)
    try await server.start()
    defer { server.stop() }
    let inspect = Process()
    let output = Pipe()
    inspect.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    inspect.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP:8766", "-sTCP:LISTEN"]
    inspect.standardOutput = output
    try inspect.run(); inspect.waitUntilExit()
    let binding = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try check(inspect.terminationStatus == 0 && binding.contains("127.0.0.1:8766") && !binding.contains("*:8766"),
              "listener is not restricted to loopback: \(binding)")
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "http://127.0.0.1:8766/live.m3u8")!
    let (playlist, result) = try await session.data(from: url)
    try check((result as? HTTPURLResponse)?.statusCode == 200, "live HTTP status")
    let text = String(decoding: playlist, as: UTF8.self)
    guard let path = text.split(separator: "\n").first(where: { $0.hasSuffix(".m4s") }) else {
        throw IntegrationFailure(message: "HTTP manifest missing fragment")
    }
    var rangeRequest = URLRequest(url: URL(string: "http://127.0.0.1:8766\(path)")!)
    rangeRequest.setValue("bytes=0-3", forHTTPHeaderField: "Range")
    let (bytes, ranged) = try await session.data(for: rangeRequest)
    try check((ranged as? HTTPURLResponse)?.statusCode == 206 && bytes == Data("test".utf8), "HTTP range bytes")
    rangeRequest.httpMethod = "HEAD"
    let (head, headed) = try await session.data(for: rangeRequest)
    try check(head.isEmpty && (headed as? HTTPURLResponse)?.statusCode == 200 &&
              (headed as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "13" &&
              (headed as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == nil, "HTTP HEAD full length")
    rangeRequest.setValue("bytes=100-", forHTTPHeaderField: "Range")
    let (invalidHead, invalidHeadResult) = try await session.data(for: rangeRequest)
    try check(invalidHead.isEmpty && (invalidHeadResult as? HTTPURLResponse)?.statusCode == 200 &&
              (invalidHeadResult as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "13",
              "HTTP HEAD must ignore unsatisfiable Range")
}

@main struct IntegrationRunner {
    static func main() async {
        var failed = 0
        do { try await encodeFixture(); print("PASS: shared-timeline writer outputs finalized HLS") }
        catch { failed += 1; print("FAIL: shared-timeline writer: \(error)") }
        do { try await verifyHTTP(); print("PASS: real loopback listener serves HLS and byte ranges") }
        catch { failed += 1; print("FAIL: real loopback listener: \(error)") }
        do { try await verifyJitteredPacing(); print("PASS: jittered 30fps source keeps its frames and timestamps") }
        catch { failed += 1; print("FAIL: jittered source pacing: \(error)") }
        do { try await verifySparseVideoRecovery(); print("PASS: sparse video resumes on the original audio timeline") }
        catch { failed += 1; print("FAIL: sparse video recovery: \(error)") }
        do { try await verifySparseVideoRecovery(realTime: true); print("PASS: live arrivals survive a three-second video gap") }
        catch { failed += 1; print("FAIL: live sparse video recovery: \(error)") }
        do { try await verifyLatestPacedSourceImage(); print("PASS: last source image fixture exported for pixel verification") }
        catch { failed += 1; print("FAIL: last source image fixture: \(error)") }
        for mode in SourcePause.allCases {
            do { try await verifySourcePause(mode); print("PASS: watchdog \(mode.rawValue)") }
            catch { failed += 1; print("FAIL: watchdog \(mode.rawValue): \(error)") }
        }
        print("HLS integration: \(9 - failed)/9 passed")
        exit(failed == 0 ? 0 : 1)
    }
}
