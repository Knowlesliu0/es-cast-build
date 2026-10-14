import Foundation

struct HLSRequest {
    static let maximumHeaderBytes = 8192
    let method: String
    let path: String
    let range: String?

    static func parse(_ data: Data) throws -> HLSRequest {
        guard data.count <= maximumHeaderBytes,
              let text = String(data: data, encoding: .utf8),
              let end = text.range(of: "\r\n\r\n"), !text.contains("\0") else {
            throw HLSError.invalidRequest
        }
        let lines = String(text[..<end.lowerBound]).components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])),
              first[1].hasPrefix("/"), !first[1].hasPrefix("//") else {
            throw HLSError.invalidRequest
        }
        var range: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HLSError.invalidRequest }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "range" {
                guard range == nil else { throw HLSError.invalidRequest }
                range = value
            }
        }
        return HLSRequest(method: String(first[0]),
                          path: String(first[1].split(separator: "?", maxSplits: 1)[0]), range: range)
    }
}

struct HLSResponse {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int, body: Data = Data(), contentType: String = "text/plain", headers: [String: String] = [:]) {
        self.status = status; self.body = body
        var fields = headers
        fields["Content-Type"] = contentType
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        fields["X-Content-Type-Options"] = "nosniff"
        self.headers = fields
    }
    private init(status: Int, body: Data, headers: [String: String]) {
        self.status = status; self.body = body; self.headers = headers
    }

    func forRequest(_ request: HLSRequest) -> HLSResponse {
        var result = self
        if request.method == "GET", status == 200, let range = request.range { result = applyingRange(range) }
        if request.method == "HEAD" {
            return HLSResponse(status: result.status, body: Data(), headers: result.headers)
        }
        return result
    }

    private func applyingRange(_ range: String) -> HLSResponse {
        func unsatisfiable() -> HLSResponse {
            HLSResponse(status: 416, headers: ["Content-Range": "bytes */\(body.count)", "Cache-Control": "no-store"])
        }
        guard range.hasPrefix("bytes="), !range.contains(","), !body.isEmpty else { return unsatisfiable() }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return unsatisfiable() }
        let lower: Int
        let upper: Int
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return unsatisfiable() }
            lower = max(0, body.count - suffix); upper = body.count - 1
        } else {
            guard let start = Int(parts[0]), start >= 0, start < body.count else { return unsatisfiable() }
            lower = start
            if parts[1].isEmpty { upper = body.count - 1 }
            else {
                guard let end = Int(parts[1]), end >= start else { return unsatisfiable() }
                upper = min(end, body.count - 1)
            }
        }
        var fields = headers
        fields["Content-Range"] = "bytes \(lower)-\(upper)/\(body.count)"
        return HLSResponse(status: 206, body: Data(body[lower...upper]),
                           contentType: headers["Content-Type"] ?? "application/octet-stream", headers: fields)
    }

    var wireData: Data {
        let reasons = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                       405: "Method Not Allowed", 416: "Range Not Satisfiable", 503: "Service Unavailable"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        for key in headers.keys.sorted() { text += "\(key): \(headers[key]!)\r\n" }
        var result = Data((text + "\r\n").utf8)
        result.append(body)
        return result
    }
}

enum HLSError: LocalizedError {
    case invalidRequest, invalidFragment, bufferLimit, closed
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "串流讀取要求格式不正確"
        case .invalidFragment: return "串流分段資料或時間不正確"
        case .bufferLimit: return "串流緩衝已達上限"
        case .closed: return "串流已停止"
        }
    }
}
