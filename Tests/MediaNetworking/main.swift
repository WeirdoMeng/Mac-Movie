import AVFoundation
import Foundation

@main
struct MediaNetworkingCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let url = URL(string: CommandLine.arguments[1])!
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "moyu-network-check", .value: "fixture"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        var denied = false
        do { _ = try await AVURLAsset(url: url).load(.duration) }
        catch {
            denied = true
        }
        guard denied else { fatalError("Default media client should be rejected by the fixture") }
        let duration = try await PlaybackNetworking.asset(url).load(.duration)
        guard duration.seconds > 0 else { fatalError("Configured asset did not load") }
        print("PASS: AVURLAsset custom User-Agent and matching cookie reach HTTP server")
        try await relayChecks(base: url.deletingLastPathComponent())
        try await webPlaybackCheck(base: url.deletingLastPathComponent())
        try await deniedPlaybackCheck(base: url.deletingLastPathComponent())
    }

    @MainActor static func relayChecks(base: URL) async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw SourceError.invalid("RELAY CHECK FAILED: " + message) }
        }
        let relay = HLSRelay(root: base.appendingPathComponent("master.m3u8"))
        let entry = try await relay.start()
        defer { relay.stop() }
        let (masterData, masterResponse) = try await URLSession.shared.data(from: entry)
        try check((masterResponse as? HTTPURLResponse)?.statusCode == 200, "master response")
        let master = String(decoding: masterData, as: UTF8.self)
        let child = master.components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1:") }!
        let (childData, _) = try await URLSession.shared.data(from: URL(string: child)!)
        let playlist = String(decoding: childData, as: UTF8.self)
        try check(!playlist.contains("fixture-token"), "signed upstream queries are not exposed in local playlist")
        let regex = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        let attributes = regex.matches(in: playlist, range: NSRange(playlist.startIndex..., in: playlist)).map { String(playlist[Range($0.range(at: 1), in: playlist)!]) }
        try check(attributes.count == 2, "key and init map rewritten")
        for address in attributes {
            let (data, response) = try await URLSession.shared.data(from: URL(string: address)!)
            try check(!data.isEmpty && (response as? HTTPURLResponse)?.statusCode == 200, "key/map forwarded")
        }
        let segment = playlist.components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1:") }!
        var request = URLRequest(url: URL(string: segment)!)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: request)
        try check(String(decoding: rangeData, as: UTF8.self) == "2345" && (rangeResponse as? HTTPURLResponse)?.statusCode == 206, "range and relative redirected base retained")
        request.httpMethod = "HEAD"; request.setValue(nil, forHTTPHeaderField: "Range")
        let (headData, headResponse) = try await URLSession.shared.data(for: request)
        try check(headData.isEmpty && (headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "10", "HEAD semantics")
        let invalid = entry.deletingLastPathComponent().appendingPathComponent("not-registered.ts")
        let (_, deniedResponse) = try await URLSession.shared.data(from: invalid)
        try check((deniedResponse as? HTTPURLResponse)?.statusCode == 404, "unregistered route rejected")
        let external = try relay.rewrite("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://protected\"\n", base: base)
        try check(external.contains("skd://protected"), "protected key protocol unchanged")
        print("PASS: HLS master, redirect base, key/map, range, HEAD, capability routes and protected key handling")
    }


    @MainActor static func webPlaybackCheck(base: URL) async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw SourceError.invalid(message) }
        }
        let resolver = WebPlaybackResolver()
        let media = try await resolver.resolve(base.appendingPathComponent("web.html"))
        try check(media.path == "/fresh.m3u8" && media.query == "token=web%2Bsignature", "runtime iframe URL and signed query preserved")
        try check(HTTPCookieStorage.shared.cookies(for: media)?.contains(where: { $0.name == "moyu-web-check" && $0.value == "fresh" }) == true, "WebKit cookie copied to media session")
        try check(resolver.evidence.contains("运行时媒体请求"), "runtime evidence recorded")
        let cancelled = WebPlaybackResolver()
        let task = Task { try await cancelled.resolve(base.appendingPathComponent("web.html")) }
        task.cancel()
        do { _ = try await task.value; throw SourceError.invalid("Cancelled web resolution succeeded") }
        catch is CancellationError {}
        print("PASS: WebKit executes iframe JS, captures runtime media URL, preserves query, syncs cookies and cancels")
    }

    @MainActor static func deniedPlaybackCheck(base: URL) async throws {
        let suite = "local.macmovie.denied-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = Library(defaults: defaults)
        defer { model.stop(); defaults.removePersistentDomain(forName: suite) }
        let episode = Episode(id: "fixture", title: "测试集", url: base.appendingPathComponent("play.html"), line: "1")
        model.detail = MovieDetail(movie: Movie(id: "fixture", title: "测试", poster: nil, remark: ""), summary: "", metadata: "", episodes: [episode])
        model.play(episode)
        let deadline = Date().addingTimeInterval(25)
        while model.playbackDiagnostics == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let diagnostic = model.playbackDiagnostics, diagnostic.contains("HLS 兼容重试"),
              diagnostic.contains("兼容请求：清单 / 403"), model.error?.contains("HTTP 403") == true else {
            throw SourceError.invalid("Expected one compatibility retry and actual HTTP 403 diagnostic: \(model.playbackDiagnostics ?? model.error ?? model.playbackStatus)")
        }
        guard diagnostic.contains("CoreMediaErrorDomain / -12660"), diagnostic.contains("NSURLErrorDomain / -1102") else {
            throw SourceError.invalid("Expected HTTP 403 to reproduce recipient error chain: \(diagnostic)")
        }
        print("PASS: denied native HLS retries once; upstream HTTP 403 stops and remains diagnosable")
    }
}
