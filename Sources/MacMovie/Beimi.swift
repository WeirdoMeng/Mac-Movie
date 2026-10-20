import Foundation

struct Movie: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let poster: URL?
    let remark: String
    var score: String = ""
}

struct Episode: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let url: URL
    let line: String
}

struct MovieDetail {
    let movie: Movie
    let summary: String
    let metadata: String
    let episodes: [Episode]
    var lines: [String: String] = [:]
    var recommendations: [Movie] = []
}

struct PageLink: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    var selected = false
}

struct FilterGroup: Identifiable {
    var id: String { title }
    let title: String
    let options: [PageLink]
}

struct CatalogPage {
    var movies: [Movie] = []
    var filters: [FilterGroup] = []
    var previous: URL?
    var next: URL?
    var pageNumber = 1
    var pageCount = 1
    var total: Int?
    var rankSections: [(String, [Movie])] = []
}

enum SourceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum HTML {
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    static func first(_ pattern: String, _ text: String) -> String {
        matches(pattern, text).first?.dropFirst().first ?? ""
    }
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">" )] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        for match in matches("&#(x[0-9a-f]+|[0-9]+);", result) {
            let value = match[1]
            let number = value.lowercased().hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            if let number, let scalar = UnicodeScalar(number) { result = result.replacingOccurrences(of: match[0], with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func attribute(_ name: String, _ tag: String) -> String {
        first("\\b" + name + "\\s*=\\s*[\"']([^\"']*)[\"']", tag)
    }
}

struct Beimi {
    static let base = URL(string: "https://v.luttt.com")!

    func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SourceError.invalid("站点请求失败，请稍后重试。")
        }
        guard data.count < 5_000_000, let html = String(data: data, encoding: .utf8) else {
            throw SourceError.invalid("页面格式不受支持。")
        }
        if html.contains("verifying your browser") || html.contains("<title>人机验证") {
            throw SourceError.invalid("站点要求浏览器验证，当前原生接入暂不可用。")
        }
        return html
    }

    func catalog(query: String = "") async throws -> [Movie] {
        try await page(Self.searchURL(query)).movies
    }

    static func searchURL(_ query: String) -> URL {
        var url = Self.base
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var parts = URLComponents(url: Self.base.appendingPathComponent("vodsearch/-------------.html"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "wd", value: query)]
            url = parts.url!
        }
        return url
    }

    func page(_ url: URL) async throws -> CatalogPage {
        Self.parsePage(try await fetch(url), url: url)
    }

    static func internalURL(_ href: String) -> URL? {
        guard let url = URL(string: HTML.clean(href), relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == base.host else { return nil }
        return url
    }

    static func parsePage(_ html: String, url: URL) -> CatalogPage {
        var page = CatalogPage(movies: movies(html))
        for group in HTML.matches("<div[^>]*class=[\"'][^\"']*hl-filter-wrap[^\"']*[\"'][^>]*>(.*?)<ul[^>]*>(.*?)</ul>", html) {
            let name = HTML.clean(HTML.first("<span[^>]*>(.*?)</span>", group[1]))
            guard !name.isEmpty, name != "已选" else { continue }
            let options = links(group[2], current: url)
            if !options.isEmpty { page.filters.append(FilterGroup(title: name, options: options)) }
        }
        let sort = HTML.matches("<a\\b[^>]*href=[\"']([^\"']*vodshow[^\"']*)[\"'][^>]*>(按[^<]+)</a>", html).compactMap { m -> PageLink? in
            guard let link = internalURL(m[1]) else { return nil }
            return PageLink(title: HTML.clean(m[2]), url: link, selected: HTML.attribute("class", m[0]).contains("active"))
        }
        if !sort.isEmpty { page.filters.append(FilterGroup(title: "排序", options: sort)) }
        let pagination = HTML.first("<ul[^>]*class=[\"'][^\"']*hl-page-wrap[^\"']*[\"'][^>]*>(.*?)</ul>", html)
        let counts = HTML.matches("([0-9]+)\\s*/\\s*([0-9]+)", HTML.clean(pagination)).first
        if let counts { page.pageNumber = Int(counts[1]) ?? 1; page.pageCount = Int(counts[2]) ?? 1 }
        for link in HTML.matches("<a\\b([^>]*)>(.*?)</a>", pagination) {
            guard !HTML.attribute("class", link[0]).contains("hl-disad"),
                  let target = internalURL(HTML.attribute("href", link[0])) else { continue }
            let title = HTML.clean(link[2])
            if title == "上一页", page.pageNumber > 1 { page.previous = target }
            if title == "下一页", page.pageNumber < page.pageCount { page.next = target }
        }
        page.total = Int(HTML.first("\\$\\(['\"]\\.hl-total['\"]\\)\\.html\\(['\"]([0-9]+)['\"]\\)", html))
        if url.path.contains("rank") {
            let tabs = HTML.matches("<a[^>]*class=[\"'][^\"']*hl-tabs-btn[^\"']*[\"'][^>]*>(.*?)</a>", html).map { HTML.clean($0[1]) }
            let lists = HTML.matches("<ul[^>]*class=[\"'][^\"']*hl-rank-list[^\"']*[\"'][^>]*>(.*?)</ul>", html)
            for (index, list) in lists.enumerated() where index < tabs.count {
                page.rankSections.append((tabs[index], movies(list[1])))
            }
            if let first = page.rankSections.first { page.movies = first.1 }
        }
        return page
    }

    static func links(_ html: String, current: URL) -> [PageLink] {
        HTML.matches("<a\\b([^>]*)>(.*?)</a>", html).compactMap { m in
            let title = HTML.clean(m[2])
            let active = HTML.attribute("class", m[0]).contains("active")
            guard !title.isEmpty, let url = internalURL(HTML.attribute("href", m[0])) ?? (active ? current : nil) else { return nil }
            return PageLink(title: title, url: url, selected: active)
        }
    }

    static func movies(_ html: String) -> [Movie] {
        var seen = Set<String>()
        let cards = HTML.matches("<li\\b[^>]*class=[\"'][^\"']*hl-list-item[^\"']*[\"'][^>]*>(.*?)</li>", html)
        if !cards.isEmpty {
            return cards.compactMap { card in
                let body = card[1]
                guard let anchor = HTML.matches("<a\\b[^>]*href=[\"'][^\"']*/voddetail/[0-9]+\\.html[\"'][^>]*>", body).first?.first else { return nil }
                let id = HTML.first("/voddetail/([0-9]+)\\.html", anchor)
                let title = HTML.clean(HTML.attribute("title", anchor))
                guard !title.isEmpty, seen.insert(id).inserted else { return nil }
                let poster = HTML.first("data-original=[\"']([^\"']+)[\"']", body)
                var remark = HTML.clean(HTML.first("<span[^>]*class=[\"'][^\"']*remarks[^\"']*[\"'][^>]*>(.*?)</span>", body))
                if remark.isEmpty {
                    remark = HTML.clean(HTML.first("<div[^>]*class=[\"']hl-item-remarks[\"'][^>]*>(.*?)</div>", body))
                    if !remark.isEmpty { remark = remark.replacingOccurrences(of: "^[0-9.]+\\s*", with: "", options: .regularExpression) }
                }
                if remark.isEmpty { remark = HTML.clean(HTML.first("<span[^>]*class=[\"']hl-text-subs hl-hidden-xs[\"'][^>]*>(.*?)</span>", body)).trimmingCharacters(in: CharacterSet(charactersIn: " /")) }
                let score = HTML.clean(HTML.first("<span[^>]*class=[\"'][^\"']*score[^\"']*[\"'][^>]*>(.*?)</span>", body))
                return Movie(id: id, title: title, poster: poster.isEmpty ? nil : URL(string: poster, relativeTo: base)?.absoluteURL, remark: remark, score: score)
            }
        }
        return HTML.matches("(<a\\b[^>]*class=[\"'][^\"']*hl-item-thumb[^\"']*[\"'][^>]*>)(.*?)</a>", html).compactMap { match in
            let tag = match[1]
            let href = HTML.attribute("href", tag)
            let id = HTML.first("/voddetail/([0-9]+)\\.html", href)
            let title = HTML.clean(HTML.attribute("title", tag))
            guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { return nil }
            let poster = HTML.attribute("data-original", tag)
            return Movie(id: id, title: title, poster: poster.isEmpty ? nil : URL(string: poster, relativeTo: base)?.absoluteURL,
                         remark: HTML.clean(HTML.first("<span[^>]*class=[\"'][^\"']*remarks[^\"']*[\"'][^>]*>(.*?)</span>", match[2])))
        }
    }

    func detail(_ movie: Movie) async throws -> MovieDetail {
        Self.parseDetail(try await fetch(Self.base.appendingPathComponent("voddetail/\(movie.id).html")), movie: movie)
    }

    static func parseDetail(_ html: String, movie: Movie) -> MovieDetail {
        var seen = Set<String>()
        let episodes: [Episode] = HTML.matches("<a\\b[^>]*href=[\"'](/vodplay/([0-9]+)-([0-9]+)-([0-9]+)\\.html)[\"'][^>]*>(.*?)</a>", html).compactMap { m in
            let title = HTML.clean(m[5])
            guard m[2] == movie.id, !title.isEmpty,
                  !["立即播放", "在线播放", "上一集", "下一集"].contains(title),
                  seen.insert(m[1]).inserted else { return nil }
            return Episode(id: m[1], title: title, url: URL(string: m[1], relativeTo: base)!.absoluteURL, line: m[3])
        }
        let metadata = ["年份", "地区", "类型", "语言", "导演", "主演"].compactMap { key -> String? in
            let value = HTML.clean(HTML.first("<li\\b[^>]*>\\s*<em[^>]*>" + key + "：</em>(.*?)</li>", html))
            return value.isEmpty ? nil : "\(key)：\(value)"
        }.joined(separator: "\n")
        let summary = HTML.clean(HTML.first("<span[^>]*class=[\"']hl-content-text[\"'][^>]*>(.*?)</span>", html))
        let lineBlock = HTML.first("<div[^>]*class=[\"'][^\"']*hl-plays-from[^\"']*[\"'][^>]*>(.*?)</div>", html)
        let names = HTML.matches("<a\\b[^>]*>(.*?)</a>", lineBlock).map { HTML.clean($0[1]) }
        var lines: [String: String] = [:]
        let ids = Array(Set(episodes.map(\.line))).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        for (index, id) in ids.enumerated() { lines[id] = index < names.count ? names[index] : "线路 \(id)" }
        return MovieDetail(movie: movie, summary: summary, metadata: metadata, episodes: episodes,
                           lines: lines, recommendations: Array(movies(html).filter { $0.id != movie.id }.prefix(12)))
    }

    func resolve(_ episode: Episode) async throws -> URL {
        try Self.playbackURL(try await fetch(episode.url))
    }

    static func playbackURL(_ html: String) throws -> URL {
        let raw = HTML.first("var\\s+player_[a-z0-9_]+\\s*=\\s*(\\{.*?\\})\\s*;?\\s*</script>", html)
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String,
              let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["m3u8", "mp4"].contains(url.pathExtension.lowercased()),
              (object["encrypt"] as? Int ?? 0) == 0 else {
            throw SourceError.invalid("该播放线路没有提供当前示例支持的直接播放地址。")
        }
        return url
    }
}
