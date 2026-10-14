import Foundation

struct TestFailure: Error { let message: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message: message) }
}
func request(_ path: String, method: String = "GET", range: String? = nil) throws -> HLSRequest {
    var header = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if let range { header += "Range: \(range)\r\n" }
    return try HLSRequest.parse(Data((header + "\r\n").utf8))
}
func populated(window: Int = 6, retained: Int = 16, count: Int = 6) throws -> HLSStore {
    let store = HLSStore(windowSize: window, retentionSize: retained)
    try store.setInitialization(Data("init".utf8))
    for index in 0..<count { try store.append(Data("segment-\(index)".utf8), duration: 2) }
    return store
}
func firstMediaURI(_ text: String) throws -> String {
    guard let uri = text.split(separator: "\n").first(where: { $0.hasSuffix(".m4s") }) else {
        throw TestFailure(message: "manifest has no media fragment")
    }
    return String(uri)
}

let tests: [(String, () throws -> Void)] = [
    ("warming is unavailable instead of stale media", {
        let store = HLSStore()
        try expect(store.response(for: try request("/live.m3u8")).status == 503, "no media must return 503")
        try store.setInitialization(Data("init".utf8))
        try store.append(Data("part".utf8), duration: 2)
        try expect(store.response(for: try request("/live.m3u8")).status == 503, "insufficient live duration")
        store.finish()
        try expect(store.response(for: try request("/live.m3u8")).status == 200, "short finalized movie is available")
    }),
    ("live manifest and initialization belong to one session", {
        let store = try populated()
        let response = store.response(for: try request("/live.m3u8"))
        let text = String(decoding: response.body, as: UTF8.self)
        try expect(response.status == 200, "live ready")
        try expect(text.contains("#EXT-X-MAP:URI=\"/s/"), "initialization map")
        try expect(text.contains("#EXT-X-MEDIA-SEQUENCE:0"), "initial sequence")
        try expect(!text.contains("ENDLIST"), "live has no end marker")
        try expect(response.headers["Cache-Control"] == "no-store", "playlist must reload")
        store.finish()
        try expect(String(decoding: store.response(for: try request("/live.m3u8")).body, as: UTF8.self).contains("ENDLIST"), "stop marks end")
    }),
    ("evicted fragments do not grow memory or enter current playlist", {
        let store = try populated(window: 3, retained: 5, count: 10)
        store.finish()
        let text = String(decoding: store.response(for: try request("/live.m3u8")).body, as: UTF8.self)
        try expect(text.contains("#EXT-X-MEDIA-SEQUENCE:7"), "sliding sequence")
        try expect(store.retainedSegmentCount == 5, "retention bound")
        let uri = try firstMediaURI(text)
        let evicted = uri.replacingOccurrences(of: "segment-7.m4s", with: "segment-0.m4s")
        try expect(store.response(for: try request(evicted)).status == 404, "old fragment unavailable")
        try expect(store.response(for: try request(uri)).body == Data("segment-7".utf8), "current bytes")
    }),
    ("invalid durations and excessive storage fail explicitly", {
        let store = HLSStore(maxBytes: 10)
        try store.setInitialization(Data([0]))
        for duration in [Double.nan, Double.infinity, 0, -1, 3.1] {
            do { try store.append(Data([1]), duration: duration); throw TestFailure(message: "invalid duration accepted") }
            catch is TestFailure { throw TestFailure(message: "invalid duration accepted") }
            catch {}
        }
        do { try store.append(Data(repeating: 1, count: 10), duration: 2); throw TestFailure(message: "memory overflow accepted") }
        catch is TestFailure { throw TestFailure(message: "memory overflow accepted") }
        catch {}
        try expect(store.retainedSegmentCount == 0, "rejected fragment not published")
    }),
    ("HEAD and byte ranges keep correct HTTP lengths", {
        let store = try populated()
        let text = String(decoding: store.response(for: try request("/live.m3u8")).body, as: UTF8.self)
        let uri = try firstMediaURI(text)
        let head = store.response(for: try request(uri, method: "HEAD"))
        try expect(head.body.isEmpty && head.headers["Content-Length"] == "9", "HEAD reports full length without body")
        let range = store.response(for: try request(uri, range: "bytes=2-4"))
        try expect(range.status == 206 && range.body == Data("gme".utf8), "range payload")
        try expect(range.headers["Content-Range"] == "bytes 2-4/9", "range metadata")
        let suffix = store.response(for: try request(uri, range: "bytes=-2"))
        try expect(suffix.body == Data("-0".utf8), "suffix range")
        try expect(store.response(for: try request(uri, range: "bytes=100-")).status == 416, "unsatisfiable range")
    }),
    ("HEAD ignores valid and invalid Range headers", {
        let store = try populated()
        let text = String(decoding: store.response(for: try request("/live.m3u8")).body, as: UTF8.self)
        let uri = try firstMediaURI(text)
        for range in ["bytes=2-4", "bytes=100-", "bytes=0-1,3-4", "unknown=0-3"] {
            let head = store.response(for: try request(uri, method: "HEAD", range: range))
            try expect(head.status == 200 && head.body.isEmpty, "HEAD must ignore Range: \(range)")
            try expect(head.headers["Content-Length"] == "9" && head.headers["Content-Range"] == nil,
                       "HEAD must describe the complete representation")
        }
    }),
    ("unsupported paths and methods expose no files", {
        let store = try populated()
        try expect(store.response(for: try request("/../../Documents/capture.mp4")).status == 404, "traversal is not a route")
        try expect(store.response(for: try request("/s/old-session/init.mp4")).status == 404, "old initialization rejected")
        try expect(store.response(for: try request("/live.m3u8", method: "POST")).status == 405, "write methods rejected")
        do { _ = try HLSRequest.parse(Data("GET / HTTP/1.1\r\n".utf8)); throw TestFailure(message: "incomplete header accepted") }
        catch is TestFailure { throw TestFailure(message: "incomplete header accepted") }
        catch {}
    })
]
var failed = 0
for (name, test) in tests {
    do { try test(); print("PASS: \(name)") }
    catch { failed += 1; print("FAIL: \(name): \(error)") }
}
print("HLS core: \(tests.count - failed)/\(tests.count) passed")
exit(failed == 0 ? 0 : 1)
