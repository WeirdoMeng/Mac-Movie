import AppKit

@main
struct MacMovieApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        if arguments.contains("--check") {
            do { try Checks.run(); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if arguments.contains("--clear-network-cache") {
            setbuf(stdout, nil)
            let cookies = HTTPCookieStorage.shared.cookies?.count ?? 0
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            print("CLEARED: network cache and \(cookies) cookies; remaining cookies=\(HTTPCookieStorage.shared.cookies?.count ?? 0), disk cache=\(URLCache.shared.currentDiskUsage), memory cache=\(URLCache.shared.currentMemoryUsage)")
        }
        let delegate = MovieAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        if arguments.contains(where: { ["--probe", "--probe-new-site", "--relay-probe", "--audit", "--window-check"].contains($0) }) {
            setbuf(stdout, nil)
            Task { @MainActor in
                do {
                    if arguments.contains("--window-check") { try await ShortcutChecks.windowCheck() }
                    else if arguments.contains("--audit") { try await Probe.audit() }
                    else if arguments.contains("--probe-new-site") { try await Probe.newSitePlayback() }
                    else { try await Probe.run(useRelay: arguments.contains("--relay-probe"), retryDeniedMedia: !arguments.contains("--no-relay")) }
                    exit(0)
                } catch {
                    let failure = error as NSError
                    print("CHECK FAILED: \(failure.localizedDescription) [\(failure.domain):\(failure.code)]")
                    if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                        print("Underlying: \(underlying.localizedDescription) [\(underlying.domain):\(underlying.code)]")
                    }
                    exit(1)
                }
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
