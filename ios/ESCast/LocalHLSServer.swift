import Foundation
import Network

/// One response per connection. Loopback binding never publishes captured content to the LAN.
final class LocalHLSServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tw.escast.http")
    private let store: HLSStore
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var requests = 0
    private var mediaRequests = 0
    private var playlistRequests = 0
    private var queuedResponses: [String: Int] = [:]
    var onFailure: ((Error) -> Void)?

    init(store: HLSStore) { self.store = store }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.listener == nil else { continuation.resume(throwing: HLSError.closed); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8766)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener; self.startup = continuation
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            self.resolveStartup(nil)
                        case .failed(let error):
                            let starting = self.startup != nil
                            self.resolveStartup(error)
                            if !starting { self.onFailure?(error) }
                            self.close()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 5) {
                        guard self.listener === listener, self.startup != nil else { return }
                        self.resolveStartup(NSError(domain: "ESCast.HTTP", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "本機串流服務啟動逾時"]))
                        self.close()
                    }
                } catch {
                    if self.startup != nil { self.resolveStartup(error) }
                    else { continuation.resume(throwing: error) }
                    self.close()
                }
            }
        }
    }

    private func resolveStartup(_ error: Error?) {
        guard let continuation = startup else { return }
        startup = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.release(id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.release(id) }
        receive(id, accumulated: Data())
    }

    private func receive(_ id: UUID, accumulated: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: HLSRequest.maximumHeaderBytes - accumulated.count + 1) {
            [weak self] data, _, ended, error in
            guard let self, self.connections[id] != nil else { return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if bytes.count > HLSRequest.maximumHeaderBytes {
                self.send(HLSResponse(status: 400), id: id); return
            }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                do {
                    let request = try HLSRequest.parse(bytes)
                    self.requests += 1
                    if request.path == "/live.m3u8" { self.playlistRequests += 1 }
                    if request.path.hasSuffix(".m4s") { self.mediaRequests += 1 }
                    self.send(self.store.response(for: request), id: id)
                }
                catch { self.send(HLSResponse(status: 400), id: id) }
            } else if ended || error != nil { self.release(id) }
            else { self.receive(id, accumulated: bytes) }
        }
    }

    private func send(_ response: HLSResponse, id: UUID) {
        guard let connection = connections[id] else { return }
        queuedResponses[String(response.status), default: 0] += 1
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in self?.release(id) })
    }
    private func release(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
    private func close() {
        listener?.cancel(); listener = nil
        for id in Array(connections.keys) { release(id) }
    }
    func stop() {
        queue.sync { resolveStartup(HLSError.closed); close() }
    }
    func diagnostic() -> [String: Any] {
        queue.sync {
            ["requests": requests, "media_requests": mediaRequests, "playlist_requests": playlistRequests,
             "queued_responses": queuedResponses, "active_connections": connections.count,
             "listener_active": listener != nil, "binding": "127.0.0.1:8766",
             "receiver_decode_verified": false, "vehicle_playback_verified": false]
        }
    }
}
