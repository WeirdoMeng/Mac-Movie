import Foundation

// Standalone regression checks so Command Line Tools can run them without XCTest/Xcode.
enum Checks {
    @MainActor static func run() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw SourceError.invalid("CHECK FAILED: " + message) }
        }
        let card = """
        <a class="hl-item-thumb hl-lazy" href="/voddetail/1252.html" title="嫁金钗" data-original="https://example.com/poster.webp"><span class="hl-lc-1 remarks">更新至第12集</span></a>
        """
        let movies = Beimi.movies(card + card + "<a href='/voddetail/12.html'>排行榜</a>")
        try require(movies.count == 1, "目录去重及排除导航")
        try require(movies.first?.remark == "更新至第12集", "更新状态")
        try require(movies.first?.poster?.host == "example.com", "海报地址")
        let movie = Movie(id: "1252", title: "嫁金钗", poster: nil, remark: "")
        let detail = Beimi.parseDetail("""
        <li class="hl-col-xs-12"><em class="hl-text-muted">年份：</em><a>2026</a></li>
        <span class="hl-content-text"><em>剧情 &amp; 简介</em></span>
        <a href="/vodplay/1252-1-1.html">立即播放</a>
        <a href="/vodplay/1252-1-1.html">第01集</a>
        <a href="/vodplay/1252-2-1.html">第01集</a>
        <a href="/vodplay/1224-1-1.html">推荐影片</a>
        """, movie: movie)
        try require(detail.episodes.count == 2, "选集去重及排除其他影片")
        try require(detail.episodes.first?.title == "第01集", "排除立即播放按钮")
        try require(detail.episodes.map(\.line) == ["1", "2"], "保留不同线路")
        try require(detail.metadata == "年份：2026", "详情字段")
        try require(detail.summary == "剧情 & 简介", "HTML 实体解码")
        let html = #"<script>var player_aaaa={"encrypt":0,"url":"https:\/\/example.com\/index.m3u8?expires=1","vod_data":{"vod_name":"样本"}}</script>"#
        let url = try Beimi.playbackURL(html)
        try require(url.host == "example.com" && url.query == "expires=1", "播放地址及查询参数")
        for invalid in [html.replacingOccurrences(of: "\"encrypt\":0", with: "\"encrypt\":2"), "<title>人机验证</title>"] {
            var rejected = false
            do { _ = try Beimi.playbackURL(invalid) } catch { rejected = true }
            try require(rejected, "拒绝不支持的资源")
        }
        let pageHTML = """
        <div class="hl-filter-wrap hl-navswiper"><div class="hl-filter-item"><span>地区</span></div><ul class="hl-filter-list">
        <li><a href="javascript:void(0)" class="active">日本</a></li>
        <li><a href="/vodshow/2-韩国----------.html">韩国</a></li></ul></div>
        <ul class="hl-page-wrap"><li><a class="hl-disad" href="/vodshow/2-日本-------1---.html">上一页</a></li>
        <li><a class="active" href="javascript:;">1</a></li><li><a href="javascript:;">1&nbsp;/&nbsp;4</a></li>
        <li><a href="/vodshow/2-日本-------2---.html">下一页</a></li></ul>
        <script>$('.hl-total').html('70');</script>
        """
        let page = Beimi.parsePage(pageHTML, url: URL(string: "https://v.luttt.com/vodshow/2-日本----------.html")!)
        try require(page.pageNumber == 1 && page.pageCount == 4 && page.total == 70, "分页及总数")
        try require(page.previous == nil && page.next?.path.contains("日本") == true, "首尾页及保留筛选条件")
        try require(page.filters.first?.options.first?.selected == true, "当前筛选状态")
        try require(page.filters.first?.options.count == 2, "筛选选项")
        try require(Beimi.internalURL("https://external.example/path") == nil && Beimi.internalURL("javascript:void(0)") == nil, "拒绝外站和脚本链接")
        let first = detail.episodes[0]
        let tenth = Episode(id: "/vodplay/1252-1-10.html", title: "第10集", url: URL(string: "https://v.luttt.com/vodplay/1252-1-10.html")!, line: "1")
        let second = Episode(id: "/vodplay/1252-1-2.html", title: "第02集", url: URL(string: "https://v.luttt.com/vodplay/1252-1-2.html")!, line: "1")
        let list = [tenth, detail.episodes[1], second, first]
        try require(PlaybackPolicy.adjacent(to: first, in: list, offset: 1)?.id == second.id, "下一集采用数字顺序")
        try require(PlaybackPolicy.adjacent(to: tenth, in: list, offset: 1) == nil, "末集不跳到其他线路")
        try require(PlaybackPolicy.equivalent(first, line: "2", episodes: list)?.id == detail.episodes[1].id, "换线保留相同集数")
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
    }
}
