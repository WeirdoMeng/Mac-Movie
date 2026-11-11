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

// Only the catalog adapter changes with the source. Playback stays in Library/WebPlaybackResolver.
struct Boju {
    static let base = URL(string: "https://ysxq.cc")!
    static let idPrefix = "boju:"

    static func internalURL(_ href: String) -> URL? {
        guard let url = URL(string: HTML.clean(href), relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == base.host, url.port == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func checkedResponse(_ data: Data, _ response: URLResponse) throws -> String {
        guard let response = response as? HTTPURLResponse else { throw SourceError.invalid("站点请求失败，请稍后重试。") }
        guard response.url?.host == base.host else { throw SourceError.invalid("站点跳转到未知地址，已停止读取。") }
        guard response.statusCode == 200 else { throw PlaybackNetworking.httpError(response) }
        guard data.count < 5_000_000, let text = String(data: data, encoding: .utf8) else {
            throw SourceError.invalid("页面格式不受支持。")
        }
        if text.contains("verifying your browser") || text.contains("Just a moment...") {
            throw SourceError.invalid("站点要求浏览器验证，当前原生接入暂不可用。")
        }
        return text
    }

    func fetch(_ url: URL) async throws -> String {
        guard Self.internalURL(url.absoluteString) == url else { throw SourceError.invalid("只支持读取当前片库页面。") }
        let (data, response) = try await URLSession.shared.data(for: PlaybackNetworking.request(url))
        return try Self.checkedResponse(data, response)
    }

    static func searchURL(_ query: String) -> URL {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return base }
        return base.appendingPathComponent("vodsearch").appendingPathComponent("\(keyword)-------------.html")
    }

    func catalog(query: String = "") async throws -> [Movie] { try await page(Self.searchURL(query)).movies }

    func page(_ url: URL) async throws -> CatalogPage {
        guard Self.internalURL(url.absoluteString) == url else { throw SourceError.invalid("只支持读取当前片库页面。") }
        if url.path == "/catalog/latest" || url.path == "/catalog/rank" {
            let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "type" })?.value ?? "0"
            let by = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "by" })?.value ?? (url.path == "/catalog/rank" ? "hits" : "time")
            return try await apiPage(url: url, values: ["type": type, "by": by], filters: [])
        }
        let html = try await fetch(url)
        if url.path.hasPrefix("/vodshow/") {
            let dataTag = HTML.matches(#"<div\b[^>]*id=["']dataList["'][^>]*>"#, html).first?.first ?? ""
            guard !dataTag.isEmpty else { throw SourceError.invalid("分类页面缺少片库数据。") }
            var values: [String: String] = [:]
            for key in ["type", "class", "area", "year", "lang", "version", "state", "letter", "time", "level", "weekday"] {
                values[key] = HTML.attribute("data-\(key)", dataTag)
            }
            values["by"] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "by" })?.value ?? "time"
            return try await apiPage(url: url, values: values, filters: Self.filters(html, current: url))
        }
        var result = CatalogPage(movies: Self.movies(html))
        if url.path.hasPrefix("/vodsearch/") {
            result.total = Int(HTML.first(#"mac-total[^<]*</strong>.*?\.html\(['"]([0-9]+)"#, html)) ?? result.movies.count
        }
        return result
    }

    private func apiPage(url: URL, values: [String: String], filters: [FilterGroup]) async throws -> CatalogPage {
        let number = max(1, Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1)
        var parameters = values
        parameters["page"] = String(number)
        var form = URLComponents()
        form.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let endpoint = Self.base.appendingPathComponent("index.php/ds_api/vod")
        var request = PlaybackNetworking.request(endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.base.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = try Self.checkedResponse(data, response)
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              json["code"] as? Int == 1, let items = json["list"] as? [[String: Any]] else {
            throw SourceError.invalid("片库接口返回的数据格式已变化。")
        }
        let movies = items.compactMap { item -> Movie? in
            guard let id = item["vod_id"] as? Int, let title = item["vod_name"] as? String, !title.isEmpty else { return nil }
            let image = item["vod_pic"] as? String ?? ""
            let score = (item["vod_score"] as? String).flatMap { $0 == "0.0" ? nil : $0 } ?? ""
            return Movie(id: Self.idPrefix + String(id), title: title,
                         poster: URL(string: image), remark: item["vod_remarks"] as? String ?? "", score: score)
        }
        let count = json["pagecount"] as? Int ?? number
        var result = CatalogPage(movies: movies, filters: filters, pageNumber: number, pageCount: count,
                                 total: json["total"] as? Int)
        if number > 1 { result.previous = Self.withPage(url, number - 1) }
        if number < count && !movies.isEmpty { result.next = Self.withPage(url, number + 1) }
        return result
    }

    private static func withPage(_ url: URL, _ number: Int) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "page" }
        items.append(URLQueryItem(name: "page", value: String(number)))
        components?.queryItems = items
        return components?.url
    }

    private static func filters(_ html: String, current: URL) -> [FilterGroup] {
        var result: [FilterGroup] = []
        for section in HTML.matches(#"<div\b[^>]*class=["'][^"']*nav-swiper rel[^"']*["'][^>]*>(.*?)</ul>\s*</div>"#, html) {
            let title = HTML.clean(HTML.first(#"<div\b[^>]*class=["'][^"']*filter-text[^"']*["'][^>]*>\s*<span>(.*?)</span>"#, section[1]))
            guard !title.isEmpty, title != "频道" else { continue }
            let options: [PageLink] = HTML.matches(#"<li\b[^>]*>.*?</li>"#, section[1]).compactMap { match in
                let item = match[0]
                let text = HTML.clean(HTML.first(#"<a\b[^>]*>(.*?)</a>"#, item))
                let selected = HTML.attribute("class", item).contains("nav-dt")
                let href = HTML.attribute("href", item)
                guard !text.isEmpty, let target = internalURL(href) ?? (selected ? current : nil) else { return nil }
                return PageLink(title: text, url: target, selected: selected)
            }
            if !options.isEmpty { result.append(FilterGroup(title: title, options: options)) }
        }
        let sort = [("最新", "time"), ("热门", "hits"), ("评分", "score")].compactMap { title, by -> PageLink? in
            var components = URLComponents(url: current, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.removeAll { $0.name == "by" || $0.name == "page" }
            items.append(URLQueryItem(name: "by", value: by))
            components?.queryItems = items
            guard let url = components?.url else { return nil }
            return PageLink(title: title, url: url,
                            selected: (URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "by" })?.value ?? "time") == by)
        }
        result.append(FilterGroup(title: "排序", options: sort))
        return result
    }

    static func movies(_ html: String) -> [Movie] {
        var seen = Set<String>()
        var result: [Movie] = []
        let cards = HTML.matches(#"<a\b[^>]*href=["']/voddetail/([0-9]+)\.html["'][^>]*>(.*?)</a>"#, html)
        for card in cards {
            let tag = card[0]
            let id = card[1]
            guard seen.insert(id).inserted else { continue }
            let title = HTML.clean(HTML.attribute("title", tag)).isEmpty
                ? HTML.clean(HTML.first(#"<h3\b[^>]*>(.*?)</h3>"#, card[2]))
                : HTML.clean(HTML.attribute("title", tag))
            guard !title.isEmpty else { continue }
            let image = HTML.attribute("data-src", tag)
            let remark = HTML.clean(HTML.first(#"<span\b[^>]*class=["'][^"']*public-list-prb[^"']*["'][^>]*>(.*?)</span>"#, card[2]))
            result.append(Movie(id: idPrefix + id, title: title, poster: URL(string: image), remark: remark))
        }
        if html.contains("class=\"search-list\"") || html.contains("search-list\"") {
            for block in HTML.matches(#"<div\b[^>]*class=["'][^"']*vod-detail[^"']*search-list[^"']*["'][^>]*>(.*?)(?=<div\b[^>]*class=["'][^"']*vod-detail[^"']*search-list|<script>\$\('\.mac-total|</body>)"#, html) {
                let id = HTML.first(#"/voddetail/([0-9]+)\.html"#, block[1])
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                let title = HTML.clean(HTML.first(#"<h3\b[^>]*class=["'][^"']*slide-info-title[^"']*["'][^>]*>(.*?)</h3>"#, block[1]))
                guard !title.isEmpty else { continue }
                let image = HTML.first(#"<img\b[^>]*data-src=["']([^"']+)["']"#, block[1])
                let remark = HTML.clean(HTML.first(#"<span\b[^>]*class=["'][^"']*slide-info-remarks cor5[^"']*["'][^>]*>(.*?)</span>"#, block[1]))
                result.append(Movie(id: idPrefix + id, title: title, poster: URL(string: image), remark: remark))
            }
        }
        return result
    }

    static func detailURL(_ movie: Movie) -> URL? {
        guard movie.id.hasPrefix(idPrefix),
              let number = Int(movie.id.dropFirst(idPrefix.count)), number > 0 else { return nil }
        return base.appendingPathComponent("voddetail/\(number).html")
    }

    func detail(_ movie: Movie) async throws -> MovieDetail {
        guard let url = Self.detailURL(movie) else { throw SourceError.invalid("旧片库影片无法在当前站点打开，请重新搜索。") }
        return Self.parseDetail(try await fetch(url), movie: movie)
    }

    static func parseDetail(_ html: String, movie: Movie) -> MovieDetail {
        let posterAddress = HTML.first(#"<div\b[^>]*class=["'][^"']*detail-pic[^"']*["'][^>]*>.*?<img\b[^>]*data-src=["']([^"']+)["']"#, html)
        let fullMovie = Movie(id: movie.id, title: movie.title,
                              poster: movie.poster ?? URL(string: posterAddress), remark: movie.remark, score: movie.score)
        let id = String(movie.id.dropFirst(idPrefix.count))
        var seen = Set<String>()
        var order: [String] = []
        let episodes = HTML.matches(#"<a\b[^>]*href=["'](/vodplay/([0-9]+)-([0-9]+)-([0-9]+)\.html)["'][^>]*>(.*?)</a>"#, html).compactMap { match -> Episode? in
            guard match[2] == id, seen.insert(match[1]).inserted else { return nil }
            let title = HTML.clean(match[5])
            guard !title.isEmpty, let url = internalURL(match[1]) else { return nil }
            if !order.contains(match[3]) { order.append(match[3]) }
            return Episode(id: match[1], title: title, url: url, line: match[3])
        }
        let lineHTML = HTML.first(#"<div\b[^>]*class=["'][^"']*anthology-tab[^"']*["'][^>]*>(.*?)</div>\s*</div>"#, html)
        let names = HTML.matches(#"<a\b[^>]*class=["'][^"']*swiper-slide[^"']*["'][^>]*>(.*?)</a>"#, lineHTML)
            .map { HTML.clean($0[1].replacingOccurrences(of: #"<span\b[^>]*class=["']badge["'][^>]*>.*?</span>"#, with: "", options: .regularExpression)) }
        var lines: [String: String] = [:]
        for (index, line) in order.enumerated() { lines[line] = index < names.count && !names[index].isEmpty ? names[index] : "线路 \(line)" }
        let summary = HTML.clean(HTML.first(#"<div\b[^>]*id=["']height_limit["'][^>]*>(.*?)</div>"#, html))
        let metadata = ["导演", "演员", "年份", "地区"].compactMap { field -> String? in
            let pattern = #"<strong\b[^>]*>\s*"# + field + #"\s*[:：]\s*</strong>(.*?)(?=</div>)"#
            let value = HTML.clean(HTML.first(pattern, html)).trimmingCharacters(in: CharacterSet(charactersIn: " ,/"))
            return value.isEmpty ? nil : "\(field)：\(value)"
        }.joined(separator: "\n")
        let recommendations = Array(movies(html).filter { $0.id != movie.id }.prefix(12))
        return MovieDetail(movie: fullMovie, summary: summary, metadata: metadata,
                           episodes: episodes, lines: lines, recommendations: recommendations)
    }
}
