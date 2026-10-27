import AVFoundation
import Foundation

enum PlaybackNetworking {
    // Match the web player's browser request profile. Its referrer policy is
    // no-referrer; do not invent a Referer or use private AVURLAsset header keys.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let httpErrorDomain = "MoyuHTTPErrorDomain"

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetHTTPUserAgentKey: userAgent,
            AVURLAssetHTTPCookiesKey: HTTPCookieStorage.shared.cookies(for: url) ?? []
        ])
    }

    static func httpError(_ response: HTTPURLResponse) -> NSError {
        NSError(domain: httpErrorDomain, code: response.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "服务器请求失败（HTTP \(response.statusCode)）。请重试或切换线路。"
        ])
    }
}

struct PlaybackIssue {
    let message: String
    let diagnostics: String

    static func isAccessDenied(_ error: Error?, statuses: [Int] = []) -> Bool {
        if statuses.contains(403) { return true }
        var current = error as NSError?
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == NSURLErrorDomain && value.code == NSURLErrorNoPermissionsToReadFile { return true }
            if value.domain == "CoreMediaErrorDomain" && value.code == -12660 { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func isCoreMedia15628(_ error: Error?) -> Bool {
        var current = error as NSError?
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == "CoreMediaErrorDomain" && value.code == -15628 { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    init(error: Error?, fallback: String, mediaURL: URL?, events: [(status: Int, uri: String?)] = [], transport: String = "浏览器兼容，无 Referer", trace: [String] = []) {
        var chain: [NSError] = []
        var current = error as NSError?
        // Error chains can be nested or malformed; never serialize userInfo,
        // signed media URLs, cookies, headers, or arbitrary server messages.
        while let value = current, chain.count < 8 {
            chain.append(value)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let statuses = events.map(\.status).filter { (400...599).contains($0) } +
            chain.filter { $0.domain == PlaybackNetworking.httpErrorDomain }.map(\.code)
        let denied = statuses.first { $0 == 401 || $0 == 403 }
        if let denied {
            message = "视频服务器拒绝访问（HTTP \(denied)）。请重试或切换线路；若网页可播，请复制诊断反馈。"
        } else if Self.isAccessDenied(error) {
            message = "视频资源访问被拒绝。请重试或切换线路；若网页可播，请复制诊断反馈。"
        } else { message = fallback }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        var lines = ["摸鱼视界播放诊断", "版本：\(version)", "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "时间：\(ISO8601DateFormatter().string(from: Date()))", "请求模式：\(transport)"]
        if let host = mediaURL?.host { lines.append("资源主机：\(host)") }
        for value in chain { lines.append("错误：\(value.domain) / \(value.code)") }
        for event in events.suffix(5) {
            let host = event.uri.flatMap(URL.init(string:))?.host ?? "未知主机"
            lines.append("媒体日志：\(event.status) / \(host)")
        }
        lines.append(contentsOf: trace.suffix(12))
        diagnostics = lines.joined(separator: "\n")
    }
}
