import Foundation

/// Only finalized immutable fragments are exposed. No file-system paths are accepted.
final class HLSStore: @unchecked Sendable {
    private struct Segment { let sequence: Int; let data: Data; let duration: Double }
    private let lock = NSLock()
    private let session = UUID().uuidString
    private let windowSize: Int
    private let retentionSize: Int
    private let maxBytes: Int
    private var initialization: Data?
    private var segments: [Segment] = []
    private var nextSequence = 0
    private var ended = false
    private var invalidated = false
    private let targetDuration = 3

    init(windowSize: Int = 6, retentionSize: Int = 16, maxBytes: Int = 32 * 1024 * 1024) {
        self.windowSize = max(1, windowSize)
        self.retentionSize = max(self.windowSize, retentionSize)
        self.maxBytes = max(1, maxBytes)
    }
    func setInitialization(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !ended, !invalidated, initialization == nil, !data.isEmpty else { throw HLSError.invalidFragment }
        guard data.count <= maxBytes else { throw HLSError.bufferLimit }
        initialization = data
    }
    func append(_ data: Data, duration: Double) throws {
        lock.lock(); defer { lock.unlock() }
        guard !ended, !invalidated else { throw HLSError.closed }
        guard initialization != nil, !data.isEmpty, duration.isFinite,
              duration > 0, duration <= Double(targetDuration) else { throw HLSError.invalidFragment }
        var candidate = segments
        candidate.append(Segment(sequence: nextSequence, data: data, duration: duration))
        if candidate.count > retentionSize { candidate.removeFirst(candidate.count - retentionSize) }
        let bytes = candidate.reduce(initialization?.count ?? 0) { $0 + $1.data.count }
        guard bytes <= maxBytes else { throw HLSError.bufferLimit }
        segments = candidate; nextSequence += 1
    }
    func finish() { lock.lock(); ended = true; lock.unlock() }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    var retainedSegmentCount: Int {
        lock.lock(); defer { lock.unlock() }; return segments.count
    }
    var producedSegmentCount: Int {
        lock.lock(); defer { lock.unlock() }; return nextSequence
    }
    var ready: Bool {
        lock.lock(); defer { lock.unlock() }; return available
    }
    private var available: Bool {
        !invalidated && initialization != nil && !segments.isEmpty &&
            (ended || segments.suffix(windowSize).reduce(0.0) { $0 + $1.duration } >= Double(3 * targetDuration))
    }
    private func path(_ file: String) -> String { "/s/\(session)/\(file)" }
    private func manifest(relative: Bool) -> Data {
        let visible = Array(segments.suffix(windowSize))
        let initializationURI = relative ? "init.mp4" : path("init.mp4")
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(targetDuration)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:\(visible.first?.sequence ?? nextSequence)\n"
        text += "#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"\(initializationURI)\"\n"
        for segment in visible {
            let duration = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), segment.duration)
            let file = "segment-\(segment.sequence).m4s"
            text += "#EXTINF:\(duration),\n\(relative ? file : path(file))\n"
        }
        if ended { text += "#EXT-X-ENDLIST\n" }
        return Data(text.utf8)
    }
    func response(for request: HLSRequest) -> HLSResponse {
        guard ["GET", "HEAD"].contains(request.method) else {
            return HLSResponse(status: 405, headers: ["Allow": "GET, HEAD"]).forRequest(request)
        }
        lock.lock(); defer { lock.unlock() }
        let response: HLSResponse
        switch request.path {
        case "/playlist.m3u":
            response = HLSResponse(status: 200,
                body: Data("#EXTM3U\n#EXTINF:-1,ES Cast live\nhttp://127.0.0.1:8766/live.m3u8\n".utf8),
                contentType: "audio/mpegurl", headers: ["Cache-Control": "no-store"])
        case "/live.m3u8":
            response = available
                ? HLSResponse(status: 200, body: manifest(relative: false), contentType: "application/vnd.apple.mpegurl",
                              headers: ["Cache-Control": "no-store"])
                : HLSResponse(status: 503, headers: ["Retry-After": "1", "Cache-Control": "no-store"])
        case path("init.mp4"):
            response = initialization.map { mediaResponse($0) } ?? HLSResponse(status: 404)
        default:
            if let segment = segments.first(where: { path("segment-\($0.sequence).m4s") == request.path }) {
                response = mediaResponse(segment.data)
            } else { response = HLSResponse(status: 404, headers: ["Cache-Control": "no-store"]) }
        }
        return response.forRequest(request)
    }
    private func mediaResponse(_ data: Data) -> HLSResponse {
        HLSResponse(status: 200, body: data, contentType: "video/mp4",
                    headers: ["Accept-Ranges": "bytes", "Cache-Control": "private, max-age=30"])
    }
    /// Explicit diagnostic recording exports only the bounded retained snapshot.
    func export(to directory: URL) throws {
        lock.lock()
        guard ended, let initialization, !segments.isEmpty else { lock.unlock(); throw HLSError.closed }
        var files = segments.map { ("segment-\($0.sequence).m4s", $0.data) }
        files.append(("init.mp4", initialization))
        let playlist = manifest(relative: true)
        lock.unlock()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"), options: .atomic)
    }
}
