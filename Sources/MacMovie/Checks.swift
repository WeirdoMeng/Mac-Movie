import Foundation

// Standalone regression checks so Command Line Tools can run them without XCTest/Xcode.
enum Checks {
    @MainActor static func run() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw SourceError.invalid("CHECK FAILED: " + message) }
        }
        let card = """
        <a class="public-list-exp" href="/voddetail/100.html" title="测试影片"><img data-src="https://example.com/poster.webp"><span class="public-list-prb">更新至第2集</span></a>
        """
        let movies = Boju.movies(card + card + "<a href='/voddetail/12.html'>导航</a>")
        try require(movies.count == 1, "目录去重及排除导航")
        try require(movies.first?.id == "boju:100" && movies.first?.remark == "更新至第2集", "新站 ID 与更新状态")
        try require(movies.first?.poster?.host == "example.com", "海报地址")
        let movie = Movie(id: "boju:100", title: "测试影片", poster: nil, remark: "")
        let detail = Boju.parseDetail("""
        <div class="detail-pic"><img data-src="https://example.com/detail.jpg"></div>
        <div id="height_limit" class="text">剧情 &amp; 简介</div>
        <strong>导演 :</strong><a>阿甲</a></div>
        <div class="anthology-tab"><div class="swiper-wrapper"><a class="swiper-slide">播剧极速<span class="badge">2</span></a><a class="swiper-slide">备用线路<span class="badge">2</span></a></div></div>
        <a class="this-link" href="/vodplay/100-6-1.html">第01集</a>
        <a class="this-link" href="/vodplay/100-4-1.html">第01集</a>
        <a class="this-link" href="/vodplay/101-1-1.html">其他影片</a>
        """, movie: movie)
        try require(detail.episodes.count == 2, "选集去重及排除其他影片")
        try require(detail.episodes.first?.title == "第01集", "选集标题")
        try require(detail.episodes.map(\.line) == ["6", "4"], "保留不同线路")
        try require(detail.lines["6"] == "播剧极速", "线路名称")
        try require(PlaybackPolicy.preferredEpisode(in: detail)?.line == "6", "默认首条线路")
        try require(detail.metadata == "导演：阿甲", "详情字段")
        try require(detail.summary == "剧情 & 简介", "HTML 实体解码")
        try require(detail.movie.poster?.absoluteString == "https://example.com/detail.jpg", "详情补全海报")
        let search = Boju.movies("""
        <div class="vod-detail style-detail cor4 search-list"><div class="detail-pic"><img data-src="https://example.com/search.jpg"></div><a href="/voddetail/102.html"><h3 class="slide-info-title">搜索结果</h3></a><span class="slide-info-remarks cor5">全1集</span></div><script>$('.mac-total').html('1');</script>
        """)
        try require(search.count == 1 && search[0].id == "boju:102", "搜索卡片解析")
        try require(Boju.internalURL("https://example.org/voddetail/1.html") == nil && Boju.internalURL("javascript:void(0)") == nil, "拒绝外站和脚本链接")
        let first = detail.episodes[0]
        let tenth = Episode(id: "/vodplay/100-6-10.html", title: "第10集", url: URL(string: "https://ysxq.cc/vodplay/100-6-10.html")!, line: "6")
        let second = Episode(id: "/vodplay/100-6-2.html", title: "第02集", url: URL(string: "https://ysxq.cc/vodplay/100-6-2.html")!, line: "6")
        let list = [tenth, detail.episodes[1], second, first]
        try require(PlaybackPolicy.adjacent(to: first, in: list, offset: 1)?.id == second.id, "下一集采用数字顺序")
        try require(PlaybackPolicy.adjacent(to: tenth, in: list, offset: 1) == nil, "末集不跳到其他线路")
        try require(PlaybackPolicy.equivalent(first, line: "4", episodes: list)?.id == detail.episodes[1].id, "换线保留相同集数")
        let record = WatchRecord(movie: movie, episode: first, position: 120, duration: 1800, updatedAt: Date())
        try require(PlaybackPolicy.resumePosition(record, episode: first) == 120 && PlaybackPolicy.resumePosition(record, episode: second) == 0, "续播只使用对应集数的进度")
        let finished = WatchRecord(movie: movie, episode: first, position: 1790, duration: 1800, updatedAt: Date())
        try require(PlaybackPolicy.resumePosition(finished, episode: first) == 0, "看完后重播从头开始")
        try require(PlaybackPolicy.time(.nan) == "00:00" && PlaybackPolicy.time(3661) == "1:01:01", "无效时间及长视频时长")
        let suite = "local.macmovie.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LocalLibrary(defaults: defaults)
        var saved = SavedLibrary(favorites: [movie], history: [record])
        saved.settings.rate = 1.5; saved.settings.autoNext = false
        try storage.save(saved)
        let restored = LocalLibrary(defaults: defaults)
        try require(restored.data.favorites.first?.id == movie.id && restored.data.history.first?.position == 120, "收藏和历史持久化")
        try require(restored.data.settings.rate == 1.5 && !restored.data.settings.autoNext, "播放设置持久化")
        let old = Movie(id: "legacy:100", title: "旧片库条目", poster: nil, remark: "")
        try storage.save(SavedLibrary(favorites: [old, movie], history: [record], settings: saved.settings))
        let migrated = Library(defaults: defaults, pageLoader: { _ in CatalogPage() })
        try require(migrated.favorites.map(\.id) == [movie.id] && migrated.history.count == 1, "切换片库后隔离旧影片")
        try require(defaults.data(forKey: LocalLibrary.key + ".previous-source") != nil &&
                    LocalLibrary(defaults: defaults).data.settings.rate == 1.5, "迁移前备份及播放设置保留")
        defaults.set(Data("broken".utf8), forKey: LocalLibrary.key)
        let recovered = LocalLibrary(defaults: defaults)
        try require(recovered.readError != nil && recovered.data.history.isEmpty && defaults.data(forKey: LocalLibrary.key + ".recovery") != nil, "本地记录损坏时保留原数据并可继续使用")
        print("PASS: 25 parser, pagination, playback-policy and persistence checks")
        try ShortcutChecks.run()
        try networkingChecks()
    }

    private static func networkingChecks() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw SourceError.invalid("NETWORK CHECK FAILED: " + message) }
        }
        let url = URL(string: "https://example.com/video.m3u8?token=private-link")!
        let request = PlaybackNetworking.request(url)
        try check(request.value(forHTTPHeaderField: "User-Agent") == PlaybackNetworking.userAgent, "页面和媒体使用一致的浏览器标识")
        try check(request.value(forHTTPHeaderField: "Referer") == nil, "遵循网页无Referer行为")
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner])
        let permission = PlaybackIssue(error: outer, fallback: "原始错误", mediaURL: url)
        try check(permission.message.contains("视频资源访问被拒绝") && permission.diagnostics.contains("-1102"), "识别嵌套资源许可错误")
        let forbidden = PlaybackIssue(error: outer, fallback: "原始错误", mediaURL: url, events: [(403, url.absoluteString)])
        try check(forbidden.message.contains("HTTP 403") && forbidden.diagnostics.contains("example.com"), "媒体错误日志保留HTTP状态")
        try check(!forbidden.diagnostics.contains("private-link") && !forbidden.diagnostics.contains("video.m3u8"), "诊断不导出地址参数或路径")
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        let fetchFailure = PlaybackIssue(error: PlaybackNetworking.httpError(response), fallback: "失败", mediaURL: nil)
        try check(fetchFailure.message.contains("HTTP 403"), "页面请求错误保留HTTP状态")
        let timeout = PlaybackIssue(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), fallback: "请求超时", mediaURL: nil)
        try check(timeout.message == "请求超时", "不将其他网络错误误报为权限错误")
        let mediaFailure = NSError(domain: "CoreMediaErrorDomain", code: -15628)
        try check(PlaybackIssue.isCoreMedia15628(mediaFailure) && !PlaybackIssue.isCoreMedia15628(inner), "仅识别对应媒体中断错误")
        print("PASS: 8 media request and redacted diagnostic checks")
    }
}
