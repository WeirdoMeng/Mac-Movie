import Foundation
import Network

// A per-playback, loopback-only HTTP bridge. Routes are random capability URLs
// registered from the current playlist, never arbitrary client-supplied URLs.
@MainActor
final class HLSRelay {
    struct Route { let url: URL; let playlist: Bool }
    struct Event { let kind: String; let host: String; let status: Int }
    private let root: URL
    private let session: URLSession
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "moyu.hls-relay")
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: CheckedContinuation<URL, Error>?
    private var routes: [String: Route] = [:]
    private var routeIDs: [URL: String] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var events: [Event] = []
    private(set) var lastError: Error?

    init(root: URL, session: URLSession = .shared) { self.root = root; self.session = session }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port?.rawValue else { return }
                            self.port = port
                            do {
                                let url = try self.register(self.root, playlist: true)
                                self.starting?.resume(returning: url); self.starting = nil
                            } catch { self.starting?.resume(throwing: error); self.starting = nil }
                        case .failed(let error):
                            self.starting?.resume(throwing: error); self.starting = nil
                        case .cancelled:
                            self.starting?.resume(throwing: CancellationError()); self.starting = nil
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: queue)
            } catch { starting?.resume(throwing: error); starting = nil }
        }
    }

    func stop() {
        starting?.resume(throwing: CancellationError()); starting = nil
        listener?.cancel(); listener = nil
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        routes.removeAll(); routeIDs.removeAll(); port = nil
    }

    deinit {
        listener?.cancel()
        for task in tasks.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
    }

    private func register(_ url: URL, playlist: Bool) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, let port else {
            throw SourceError.invalid("播放清单包含不支持的资源地址。")
        }
        let id: String
        if let existing = routeIDs[url] { id = existing }
        else {
            guard routes.count < 50_000 else { throw SourceError.invalid("播放清单资源数量超过限制。") }
            id = UUID().uuidString + (playlist ? ".m3u8" : "." + (url.pathExtension.isEmpty ? "bin" : url.pathExtension))
            routes[id] = Route(url: url, playlist: playlist); routeIDs[url] = id
        }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(id)")!
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            let watchdog = Task {
                do { try await Task.sleep(nanoseconds: 30_000_000_000); connection.cancel() } catch {}
            }
            defer { watchdog.cancel() }
            do { try await self.handle(connection) }
            catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    self.lastError = error
                    try? await self.respond(connection, status: 502, headers: [:], body: Data(), head: false)
                }
            }
            connection.cancel(); self.connections[id] = nil; self.tasks[id] = nil
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: complete ? URLError(.networkConnectionLost) : URLError(.badServerResponse)) }
            }
        }
    }

    private func handle(_ connection: NWConnection) async throws {
        var input = Data()
        while input.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard input.count < 16_384 else { throw URLError(.badServerResponse) }
            input.append(try await receive(connection))
            try Task.checkCancellation()
        }
        let lines = String(decoding: input, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        guard requestLine.count == 3, ["GET", "HEAD"].contains(String(requestLine[0])) else {
            try await respond(connection, status: 405, headers: [:], body: Data(), head: false); return
        }
        let head = requestLine[0] == "HEAD"
        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == token, let route = routes[String(parts[1])] else {
            try await respond(connection, status: 404, headers: [:], body: Data(), head: head); return
        }
        var request = PlaybackNetworking.request(route.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = head && !route.playlist ? "HEAD" : "GET"
        // Only forward byte-range semantics. Native media session headers and
        // loopback cookies must never be sent to the upstream origin.
        if !route.playlist {
            for line in lines.dropFirst() {
                let header = line.split(separator: ":", maxSplits: 1)
                if header.count == 2, ["range", "if-range"].contains(header[0].lowercased()) {
                    request.setValue(header[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: String(header[0]))
                }
            }
        }
        let result = try await Self.fetch(request, session: session, limit: route.playlist ? 4_000_000 : 16_000_000)
        try Task.checkCancellation()
        let response = result.1
        let status = response.statusCode
        events.append(Event(kind: route.playlist ? "清单" : "媒体", host: response.url?.host ?? route.url.host ?? "", status: status))
        if events.count > 12 { events.removeFirst(events.count - 12) }
        guard (200...299).contains(status) else {
            try await respond(connection, status: status, headers: [:], body: Data(), head: head); return
        }
        var body = result.0
        var headers: [String: String] = [:]
        let playlist = route.playlist || body.starts(with: Data("#EXTM3U".utf8))
        if playlist {
            guard let text = String(data: body, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                throw SourceError.invalid("视频服务器没有返回有效的播放清单。")
            }
            body = Data(try rewrite(text, base: response.url ?? route.url).utf8)
            headers["Content-Type"] = "application/vnd.apple.mpegurl"
        } else {
            headers["Content-Type"] = response.mimeType ?? "application/octet-stream"
            for name in ["Content-Range", "Accept-Ranges"] {
                if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            if head, let length = response.value(forHTTPHeaderField: "Content-Length") { headers["Content-Length"] = length }
        }
        try await respond(connection, status: playlist ? 200 : status, headers: headers, body: body, head: head)
    }

    nonisolated private static func fetch(_ request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = rawResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(response.statusCode), request.httpMethod != "HEAD" else { return (Data(), response) }
        guard response.expectedContentLength <= limit else { throw SourceError.invalid("单个媒体分片超过兼容模式大小限制。") }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw SourceError.invalid("单个媒体分片超过兼容模式大小限制。") }
            data.append(byte)
        }
        return (data, response)
    }

    func rewrite(_ playlist: String, base: URL) throws -> String {
        let regex = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        var nextIsPlaylist = false
        return try playlist.components(separatedBy: .newlines).map { line in
            if line.hasPrefix("#") {
                nextIsPlaylist = line.hasPrefix("#EXT-X-STREAM-INF:")
                var output = line
                let isPlaylist = ["#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-RENDITION-REPORT:"].contains { line.hasPrefix($0) }
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let range = Range(match.range(at: 1), in: output), let url = URL(string: String(output[range]), relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
                    if ["data", "skd"].contains(url.scheme?.lowercased() ?? "") { continue }
                    output.replaceSubrange(range, with: try register(url, playlist: isPlaylist || url.pathExtension.lowercased() == "m3u8").absoluteString)
                }
                return output
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            guard let url = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
            let isPlaylist = nextIsPlaylist || url.pathExtension.lowercased() == "m3u8"
            nextIsPlaylist = false
            return try register(url, playlist: isPlaylist).absoluteString
        }.joined(separator: "\n")
    }

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data, head: Bool) async throws {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(body.count) }
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        var data = Data("HTTP/1.1 \(status) Response\r\n".utf8)
        for (key, value) in headers where !value.contains("\r") && !value.contains("\n") { data.append(Data("\(key): \(value)\r\n".utf8)) }
        data.append(Data("\r\n".utf8))
        if !head { data.append(body) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
