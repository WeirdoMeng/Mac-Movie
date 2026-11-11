import WebKit

// Executes the actual episode page and its frames in an app-owned WebKit session.
// Only media URLs and scoped cookies leave WebKit; no browser-profile data is read.
@MainActor
final class WebPlaybackResolver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var candidate: (url: URL, rank: Int)?
    private var navigationError: Error?
    private var cancelled = false
    private(set) var evidence = "WebView 尚未获取媒体"

    func resolve(_ page: URL) async throws -> URL {
        let controller = WKUserContentController()
        controller.add(self, name: "moyuMedia")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        // The background page must never start a second audible player.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 540), configuration: configuration)
        webView = view
        defer { cancel() }
        view.customUserAgent = PlaybackNetworking.userAgent
        view.navigationDelegate = self
        var request = PlaybackNetworking.request(page)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for cookie in HTTPCookieStorage.shared.cookies(for: page) ?? [] {
            await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        view.load(request)
        for tick in 0..<100 {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            if let navigationError { throw navigationError }
            // Prefer the URL actually used by the running player over static config.
            if let candidate, (candidate.rank >= 3 && tick >= 8) || tick >= 32 {
                let cookies = await configuration.websiteDataStore.httpCookieStore.allCookies()
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                for cookie in cookies where Self.matches(cookie, url: candidate.url) || Self.matches(cookie, url: page) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                let count = cookies.filter { Self.matches($0, url: candidate.url) }.count
                evidence = "WebView：\(candidate.rank >= 3 ? "运行时媒体请求" : "执行后播放器配置")；适用 Cookie 数：\(count)"
                return candidate.url
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SourceError.invalid("网页播放参数获取超时，请重试或切换线路。")
    }

    func cancel() {
        cancelled = true
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "moyuMedia")
        webView?.navigationDelegate = nil
        webView = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !cancelled, let object = message.body as? [String: Any],
              let address = object["url"] as? String, address.count < 16_384,
              let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              ["m3u8", "mp4"].contains(url.pathExtension.lowercased()) else { return }
        let rank = object["runtime"] as? Bool == true ? 3 : (message.frameInfo.isMainFrame ? 1 : 2)
        if candidate == nil || rank > candidate!.rank { candidate = (url, rank) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { decisionHandler(.cancel); return }
        decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { navigationError = error }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError = SourceError.invalid("网页播放参数进程已退出，请重试。")
    }

    private static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !cookie.isSecure || url.scheme == "https",
              cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatches = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
        let path = url.path.isEmpty ? "/" : url.path
        return domainMatches && (path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))))
    }

    private static let script = #"""
    (() => {
      const seen = new Set();
      function report(value, runtime) {
        try {
          const u = new URL(value, location.href);
          if (!/^https?:$/.test(u.protocol) || !/\.(m3u8|mp4)$/i.test(u.pathname)) return;
          const key = String(runtime) + u.href;
          if (seen.has(key)) return;
          seen.add(key);
          window.webkit.messageHandlers.moyuMedia.postMessage({url: u.href, runtime: !!runtime});
        } catch (_) {}
      }
      const fetch = window.fetch;
      window.fetch = function(input, ...args) {
        report(typeof input === 'string' ? input : input && input.url, true);
        return fetch.call(this, input, ...args);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...args) {
        report(url, true); return open.call(this, method, url, ...args);
      };
      try { new PerformanceObserver(list => list.getEntries().forEach(e => report(e.name, true))).observe({type:'resource', buffered:true}); } catch (_) {}
      function scan() {
        document.querySelectorAll('video, audio').forEach(v => {
          v.muted = true; v.pause(); report(v.currentSrc || v.src, true);
          v.querySelectorAll('source').forEach(s => report(s.src, true));
        });
        // Inspect the live JS object, including values populated after scripts run.
        Object.keys(window).filter(k => /^(?:mac_)?player_[a-z0-9_]+$/i.test(k)).forEach(k => {
          try { const p = window[k]; if (p && Number(p.encrypt || 0) === 0) report(p.url, false); } catch (_) {}
        });
      }
      document.addEventListener('play', e => { e.target.muted = true; e.target.pause(); }, true);
      setInterval(scan, 200);
    })();
    """#
}
