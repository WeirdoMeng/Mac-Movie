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
    static let base = URL(string: "https://www.5dy17.top")!

    func fetch(_ url: URL) async throws -> String {
        guard Self.internalURL(url.absoluteString) == url else {
            throw SourceError.invalid("只支持读取摸鱼视界当前片库页面。")
        }
        let request = PlaybackNetworking.request(url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SourceError.invalid("站点请求失败，请稍后重试。")
        }
        guard response.url?.host == Self.base.host else {
            throw SourceError.invalid("站点跳转到未知地址，已停止读取。")
        }
        guard response.statusCode == 200 else { throw PlaybackNetworking.httpError(response) }
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
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return Self.base }
        return Self.base.appendingPathComponent("vodsearch").appendingPathComponent("\(keyword)-------------.html")
    }

    func page(_ url: URL) async throws -> CatalogPage {
        Self.parsePage(try await fetch(url), url: url)
    }

    static func internalURL(_ href: String) -> URL? {
        guard let url = URL(string: HTML.clean(href), relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == base.host, url.port == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func parsePage(_ html: String, url: URL) -> CatalogPage {
        var page = CatalogPage(movies: movies(html))
        let filterPattern = #"<div\b[^>]*class=["'][^"']*module-class-item[^"']*["'][^>]*>\s*<div\b[^>]*class=["'][^"']*module-item-title[^"']*["'][^>]*>(.*?)</div>\s*<div\b[^>]*class=["'][^"']*module-item-box[^"']*["'][^>]*>(.*?)</div>"#
        for group in HTML.matches(filterPattern, html) {
            let name = HTML.clean(group[1])
            guard !name.isEmpty else { continue }
            let options = links(group[2], current: url)
            if !options.isEmpty { page.filters.append(FilterGroup(title: name, options: options)) }
        }
        let pagination = HTML.first(#"<div\b[^>]*id=["']page["'][^>]*>(.*?)</div>"#, html)
        page.pageNumber = Int(HTML.first(#"<span\b[^>]*class=["'][^"']*page-current[^"']*["'][^>]*>\s*([0-9]+)\s*</span>"#, pagination)) ?? 1
        for link in HTML.matches(#"<a\b[^>]*>(.*?)</a>"#, pagination) {
            guard let target = internalURL(HTML.attribute("href", link[0])) else { continue }
            let title = HTML.clean(link[1])
            if title == "上一页", page.pageNumber > 1 { page.previous = target }
            if title == "下一页" { page.next = target }
            if title == "尾页" {
                page.pageCount = Int(HTML.first(#"-([0-9]+)---\.html"#, target.path)) ?? page.pageCount
            } else if let number = Int(title) {
                page.pageCount = max(page.pageCount, number)
            }
        }
        page.total = Int(HTML.first(#"找到\s*([0-9]+)\s*部"#, html))
        if url.path == "/label/hot.html" {
            page.rankSections = rankingSections(html)
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
        let posterCards = HTML.matches(#"<a\b[^>]*class=["'][^"']*module-poster-item[^"']*["'][^>]*>.*?</a>"#, html)
        let posters = posterCards.compactMap { match -> Movie? in
            let body = match[0]
            let number = HTML.first(#"/voddetail/([0-9]+)\.html"#, HTML.attribute("href", body))
            let title = HTML.clean(HTML.attribute("title", body))
            guard !number.isEmpty, !title.isEmpty, seen.insert(number).inserted else { return nil }
            let image = HTML.clean(HTML.attribute("data-original", body))
            let remark = HTML.clean(HTML.first(#"<div\b[^>]*class=["'][^"']*module-item-note[^"']*["'][^>]*>(.*?)</div>"#, body))
            let rating = HTML.clean(HTML.first(#"<div\b[^>]*class=["'][^"']*module-item-douban[^"']*["'][^>]*>(.*?)</div>"#, body))
            return Movie(id: "5dy:\(number)", title: title,
                         poster: image.isEmpty ? nil : URL(string: image, relativeTo: base)?.absoluteURL,
                         remark: remark, score: HTML.first(#"([0-9]+(?:\.[0-9]+)?)"#, rating))
        }
        if !posters.isEmpty { return posters }

        let searchCards = HTML.matches(#"(<a\b[^>]*class=["'][^"']*module-card-item-poster[^"']*["'][^>]*>.*?</a>)(.*?)(?=<div\b[^>]*class=["'][^"']*module-card-item-footer)"#, html)
        return searchCards.compactMap { match in
            let number = HTML.first(#"/voddetail/([0-9]+)\.html"#, HTML.attribute("href", match[1]))
            let highlightedTitle = HTML.first(#"<div\b[^>]*class=["'][^"']*module-card-item-title[^"']*["'][^>]*>(.*?)</div>"#, match[2])
            let title = HTML.clean(highlightedTitle.replacingOccurrences(of: #"</?em\b[^>]*>"#, with: "", options: .regularExpression))
            guard !number.isEmpty, !title.isEmpty, seen.insert(number).inserted else { return nil }
            let image = HTML.clean(HTML.attribute("data-original", match[1]))
            let remark = HTML.clean(HTML.first(#"<div\b[^>]*class=["'][^"']*module-item-note[^"']*["'][^>]*>(.*?)</div>"#, match[1]))
            return Movie(id: "5dy:\(number)", title: title,
                         poster: image.isEmpty ? nil : URL(string: image, relativeTo: base)?.absoluteURL,
                         remark: remark)
        }
    }

    private static func rankingSections(_ html: String) -> [(String, [Movie])] {
        let pattern = #"<div\b[^>]*class=["'][^"']*module-paper-item module-item[^"']*["'][^>]*>(.*?)(?=<div\b[^>]*class=["'][^"']*module-paper-item module-item|$)"#
        return HTML.matches(pattern, html).compactMap { section in
            let rawTitle = HTML.clean(HTML.first(#"<h3\b[^>]*class=["'][^"']*module-paper-item-title[^"']*["'][^>]*>(.*?)</h3>"#, section[1]))
            guard !rawTitle.isEmpty else { return nil }
            let title = rawTitle.replacingOccurrences(of: #"(总榜|月榜|周榜|日榜)$"#, with: "·$1", options: .regularExpression)
            var seen = Set<String>()
            let entries = HTML.matches(#"<a\b[^>]*href=["'](/voddetail/([0-9]+)\.html)["'][^>]*>(.*?)</a>"#, section[1]).compactMap { match -> Movie? in
                let number = match[2]
                let name = HTML.clean(HTML.first(#"<span\b[^>]*class=["'][^"']*module-paper-item-infotitle[^"']*["'][^>]*>(.*?)</span>"#, match[3]))
                guard !name.isEmpty, seen.insert(number).inserted else { return nil }
                let remark = HTML.clean(HTML.first(#"<p\b[^>]*>(.*?)</p>"#, match[3]))
                return Movie(id: "5dy:\(number)", title: name, poster: nil, remark: remark)
            }
            guard !entries.isEmpty else { return nil }
            return (title, Array(entries.prefix(10)))
        }
    }

    static func detailURL(_ movie: Movie) -> URL? {
        let number = String(movie.id.dropFirst("5dy:".count))
        guard movie.id.hasPrefix("5dy:"), !number.isEmpty,
              number.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) else {
            return nil
        }
        return Self.base.appendingPathComponent("voddetail/\(number).html")
    }

    func detail(_ movie: Movie) async throws -> MovieDetail {
        guard let url = Self.detailURL(movie) else {
            throw SourceError.invalid("这部影片属于旧片库，请在新片库重新搜索。")
        }
        return Self.parseDetail(try await fetch(url), movie: movie)
    }

    static func parseDetail(_ html: String, movie: Movie) -> MovieDetail {
        var seen = Set<String>()
        var lineOrder: [String] = []
        let posterAddress = HTML.clean(HTML.first(#"<div\b[^>]*class=["'][^"']*module-info-poster[^"']*["'][^>]*>.*?<img\b[^>]*data-original=["']([^"']+)["']"#, html))
        let poster = posterAddress.isEmpty ? nil : URL(string: posterAddress, relativeTo: base)?.absoluteURL
        let fullMovie = Movie(id: movie.id, title: movie.title, poster: movie.poster ?? poster,
                              remark: movie.remark, score: movie.score)
        let numericID = movie.id.hasPrefix("5dy:") ? String(movie.id.dropFirst("5dy:".count)) : ""
        let episodePattern = #"<a\b[^>]*class=["'][^"']*module-play-list-link[^"']*["'][^>]*href=["'](/vodplay/([0-9]+)-([0-9]+)-([0-9]+)\.html)["'][^>]*>(.*?)</a>"#
        let episodes: [Episode] = HTML.matches(episodePattern, html).compactMap { m in
            let title = HTML.clean(m[5])
            guard m[2] == numericID, !title.isEmpty,
                  seen.insert(m[1]).inserted else { return nil }
            if !lineOrder.contains(m[3]) { lineOrder.append(m[3]) }
            return Episode(id: m[1], title: title, url: URL(string: m[1], relativeTo: base)!.absoluteURL, line: m[3])
        }
        let metadata = ["导演", "编剧", "主演", "上映", "更新", "集数"].compactMap { key -> String? in
            let pattern = #"<span\b[^>]*class=["'][^"']*module-info-item-title[^"']*["'][^>]*>\s*"# + NSRegularExpression.escapedPattern(for: key) + #"：\s*</span>\s*<div\b[^>]*class=["'][^"']*module-info-item-content[^"']*["'][^>]*>(.*?)</div>"#
            let value = HTML.clean(HTML.first(pattern, html)).trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            return value.isEmpty ? nil : "\(key)：\(value)"
        }.joined(separator: "\n")
        let summary = HTML.clean(HTML.first(#"<div\b[^>]*class=["'][^"']*module-info-introduction-content[^"']*["'][^>]*>(.*?)</div>"#, html))
        let names = HTML.matches(#"<div\b[^>]*class=["'][^"']*module-tab-item tab-item[^"']*["'][^>]*>(.*?)</div>"#, html)
            .map { HTML.clean(HTML.first(#"<span\b[^>]*>(.*?)</span>"#, $0[1])) }
        var lines: [String: String] = [:]
        for (index, id) in lineOrder.enumerated() {
            lines[id] = index < names.count && !names[index].isEmpty ? names[index] : "线路 \(id)"
        }
        return MovieDetail(movie: fullMovie, summary: summary, metadata: metadata, episodes: episodes,
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
