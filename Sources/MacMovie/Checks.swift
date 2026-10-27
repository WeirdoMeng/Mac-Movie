import Foundation

// Standalone regression checks so Command Line Tools can run them without XCTest/Xcode.
enum Checks {
    @MainActor static func run() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw SourceError.invalid("CHECK FAILED: " + message) }
        }
        let card = """
        <a class="module-poster-item module-item" href="/voddetail/809444.html" title="兰香如故"><img data-original="https://example.com/poster.webp"><div class="module-item-note">更新至第47集</div><div class="module-item-douban">9.0</div></a>
        """
        let movies = Beimi.movies(card + card + "<a href='/voddetail/12.html'>排行榜</a>")
        try require(movies.count == 1, "目录去重及排除导航")
        try require(movies.first?.id == "5dy:809444" && movies.first?.remark == "更新至第47集", "新站 ID 与更新状态")
        try require(movies.first?.poster?.host == "example.com", "海报地址")
        let movie = Movie(id: "5dy:809444", title: "兰香如故", poster: nil, remark: "")
        let detail = Beimi.parseDetail("""
        <div class="module-info-poster"><img data-original="/upload/sample.jpg"></div>
        <span class="module-info-item-title">导演：</span><div class="module-info-item-content">阿甲</div>
        <div class="module-info-introduction-content">剧情 &amp; 简介</div>
        <div class="module-tab-item tab-item"><span>极清蓝光</span></div>
        <div class="module-tab-item tab-item"><span>备用线路</span></div>
        <a class="module-play-list-link" href="/vodplay/809444-10-1.html">第01集</a>
        <a class="module-play-list-link" href="/vodplay/809444-4-1.html">第01集</a>
        <a class="module-play-list-link" href="/vodplay/1224-1-1.html">其他影片</a>
        """, movie: movie)
        try require(detail.episodes.count == 2, "选集去重及排除其他影片")
        try require(detail.episodes.first?.title == "第01集", "选集标题")
        try require(detail.episodes.map(\.line) == ["10", "4"], "保留不同线路")
        try require(detail.lines["10"] == "极清蓝光", "线路名称")
        try require(PlaybackPolicy.preferredEpisode(in: detail)?.line == "10", "优先选择已验证的蓝光线路")
        try require(detail.metadata == "导演：阿甲", "详情字段")
        try require(detail.summary == "剧情 & 简介", "HTML 实体解码")
        try require(detail.movie.poster?.absoluteString == "https://www.5dy17.top/upload/sample.jpg", "详情补全排行榜海报")
        let html = #"<script>var player_aaaa={"encrypt":0,"url":"https:\/\/example.com\/index.m3u8?expires=1","vod_data":{"vod_name":"样本"}}</script>"#
        let url = try Beimi.playbackURL(html)
        try require(url.host == "example.com" && url.query == "expires=1", "播放地址及查询参数")
        for invalid in [html.replacingOccurrences(of: "\"encrypt\":0", with: "\"encrypt\":2"), "<title>人机验证</title>"] {
            var rejected = false
            do { _ = try Beimi.playbackURL(invalid) } catch { rejected = true }
            try require(rejected, "拒绝不支持的资源")
        }
        let pageHTML = """
        <div class="module-class-item"><div class="module-item-title">地区</div><div class="module-item-box">
        <a href="javascript:void(0)" class="active">日本</a><a href="/vodshow/2-韩国----------.html">韩国</a></div></div>
        <div id="page"><span class="page-current">1</span><a href="/vodshow/2-日本-------2---.html">下一页</a><a href="/vodshow/2-日本-------4---.html">尾页</a></div>
        找到 70 部
        """
        let page = Beimi.parsePage(pageHTML, url: URL(string: "https://www.5dy17.top/vodshow/2-日本----------.html")!)
        try require(page.pageNumber == 1 && page.pageCount == 4 && page.total == 70, "分页及总数")
        try require(page.previous == nil && page.next?.path.contains("日本") == true, "首尾页及保留筛选条件")
        try require(page.filters.first?.options.first?.selected == true, "当前筛选状态")
        try require(page.filters.first?.options.count == 2, "筛选选项")
        try require(Beimi.internalURL("https://v.luttt.com/voddetail/1.html") == nil && Beimi.internalURL("javascript:void(0)") == nil, "拒绝旧站和脚本链接")
        let first = detail.episodes[0]
        let tenth = Episode(id: "/vodplay/809444-10-10.html", title: "第10集", url: URL(string: "https://www.5dy17.top/vodplay/809444-10-10.html")!, line: "10")
        let second = Episode(id: "/vodplay/809444-10-2.html", title: "第02集", url: URL(string: "https://www.5dy17.top/vodplay/809444-10-2.html")!, line: "10")
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
