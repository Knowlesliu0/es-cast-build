import Foundation
import AVFoundation
import CoreVideo

enum SourcePause: String, CaseIterable {
    case noSamples, videoOnly, bothStopped
}

private final class ObservedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [NSError] = []
    func record(_ error: Error) { lock.lock(); errors.append(error as NSError); lock.unlock() }
    var snapshot: [NSError] { lock.lock(); defer { lock.unlock() }; return errors }
}

func verifySourcePause(_ mode: SourcePause) async throws {
    let queue = DispatchQueue(label: "tw.escast.watchdog.\(mode.rawValue)")
    let store = HLSStore(windowSize: 12)
    let writer = LiveHLSWriter(store: store, queue: queue)
    let failures = ObservedFailures()
    writer.onFailure = { failures.record($0) }
    queue.sync { writer.startMonitoring() }
    do {
        switch mode {
        case .noSamples:
            break
        case .videoOnly:
            let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw IntegrationFailure(message: "missing video track") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(output)
            try check(reader.startReading(), "single-track reader did not start")
            guard let sample = output.copyNextSampleBuffer() else {
                throw IntegrationFailure(message: "missing video sample")
            }
            try queue.sync { try writer.append(sample, type: .video) }
            reader.cancelReading()
        case .bothStopped:
            _ = try await feedFixture(writer, queue: queue)
            for _ in 0..<20 {
                if store.ready { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(store.ready, "stream must be ready before both source tracks stop")
        }
        for _ in 0..<80 {
            if !failures.snapshot.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let observed = failures.snapshot
        let expectedCode = mode == .bothStopped ? 12 : 11
        try check(observed.count == 1 && observed.first?.domain == "ESCast.HLS" && observed.first?.code == expectedCode,
                  "missing single source-timeout callback; got \(observed)")
        let response = store.response(for: HLSRequest(method: "GET", path: "/live.m3u8", range: nil))
        try check(!store.ready && response.status == 503, "failed stream still publishes a ready live playlist")
        do {
            try await writer.finish()
            throw IntegrationFailure(message: "finish hid the source timeout")
        } catch let error as NSError {
            try check(error.domain == "ESCast.HLS" && error.code == expectedCode, "finish must retain the source error")
        }
        try check(!store.ready && failures.snapshot.count == 1, "finish restored ready or duplicated failure")
    } catch {
        try? await writer.finish()
        throw error
    }
}
