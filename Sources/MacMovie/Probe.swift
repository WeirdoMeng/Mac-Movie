import SwiftUI
import AVKit
import CoreImage
import QuartzCore

enum Probe {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw SourceError.invalid(message) }
    }

    @MainActor static func wait(_ label: String, seconds: Double = 45, model: Library, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if let error = model.error { throw SourceError.invalid("\(label)：\(error)") }
            if Date() >= deadline { throw SourceError.invalid("\(label)：等待超时") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    @MainActor static func audit() async throws {
        let source = Beimi()
        async let home = source.page(Beimi.base)
        async let category = source.page(URL(string: "https://v.luttt.com/vodshow/2-----------.html")!)
        async let ranking = source.page(URL(string: "https://v.luttt.com/label/rank/")!)
        async let latest = source.page(URL(string: "https://v.luttt.com/map/")!)
        async let search = source.page(Beimi.searchURL("唐"))
        let (h, c, r, l, s) = try await (home, category, ranking, latest, search)
        try require(!h.movies.isEmpty && !c.movies.isEmpty && !l.movies.isEmpty, "首页、分类或最近更新为空")
        try require(!c.filters.isEmpty && c.pageCount > 1 && c.next != nil, "分类筛选或分页未识别")
        try require(!r.rankSections.isEmpty && !r.movies.isEmpty, "排行分组未识别")
        try require(!s.movies.isEmpty && s.next != nil, "搜索分页未识别")
        print("AUDIT home=\(h.movies.count), category=\(c.movies.count), filters=\(c.filters.map(\.title)), pages=\(c.pageCount), latest=\(l.movies.count), rankSections=\(r.rankSections.count), search=\(s.movies.count)/\(s.pageCount) pages")
        let page2 = try await source.page(c.next!)
        try require(page2.pageNumber == 2 && page2.previous != nil && page2.movies.first?.id != c.movies.first?.id, "分类下一页没有切换数据")
        let search2 = try await source.page(s.next!)
        try require(search2.pageNumber == 2 && search2.movies.first?.id != s.movies.first?.id, "搜索下一页没有切换数据")
        if let option = c.filters.first(where: { $0.title == "地区" })?.options.first(where: { $0.title == "日本" }) {
            let filtered = try await source.page(option.url)
            try require(filtered.filters.first(where: { $0.title == "地区" })?.options.contains(where: { $0.title == "日本" && $0.selected }) == true, "地区筛选未正确保留")
            print("AUDIT region=日本 movies=\(filtered.movies.count)")
        } else { throw SourceError.invalid("地区筛选选项缺失") }
        for (title, path) in [("月榜", "/label/rankmonth.html"), ("周榜", "/label/rankweek.html")] {
            let page = try await source.page(URL(string: path, relativeTo: Beimi.base)!.absoluteURL)
            try require(!page.movies.isEmpty, "\(title)没有影片")
            print("AUDIT \(title)=\(page.movies.count), sections=\(page.rankSections.count)")
        }
        print("PASS: live catalog, filters, pagination, search, latest and total/month/week rankings")
    }

    @MainActor static func run() async throws {
        let suite = "local.macmovie.probe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = LocalLibrary(defaults: defaults)
        var saved = SavedLibrary(); saved.settings.muted = true
        try store.save(saved)
        let model = Library(defaults: defaults)
        defer { model.stop(); defaults.removePersistentDomain(forName: suite) }
        let movies = try await Beimi().catalog(query: "嫁金钗")
        guard let movie = movies.first(where: { $0.id == "1252" }) else { throw SourceError.invalid("搜索样本未找到") }
        model.select(movie)
        try await wait("加载详情", model: model) { model.detail != nil && !model.detailLoading }
        guard let episode = model.detail?.episodes.first else { throw SourceError.invalid("样本没有剧集") }
        print("PROBE detail: \(movie.title), episodes=\(model.detail!.episodes.count), lines=\(model.detail!.lines)")
        model.toggleFavorite(movie)
        try require(LocalLibrary(defaults: defaults).data.favorites.contains(where: { $0.id == movie.id }), "收藏保存失败")
        model.play(episode, from: 30)
        model.pauseForHiding()
        try await wait("打开播放流", model: model) { model.player.currentItem != nil }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        model.player.currentItem!.add(output)
        try await wait("隐藏期间加载完成", model: model) { !model.resolving }
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(!model.isPlaying && model.player.rate == 0, "加载期间隐藏后仍自动播放")
        model.togglePlayback()
        try await wait("开始播放并定位到 30 秒", model: model) { !model.resolving && model.isPlaying && model.position >= 30 }
        print("PROBE playing: duration=\(model.duration), position=\(model.position)")
        model.pauseForHiding()
        let hiddenPosition = model.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(!model.isPlaying && model.player.rate == 0 && abs(model.player.currentTime().seconds - hiddenPosition) < 0.5, "隐藏没有暂停并保留进度")
        model.togglePlayback()
        try await wait("隐藏后手动恢复播放", model: model) { model.isPlaying }
        print("PROBE hide pauses during loading/playing; manual resume PASS")
        model.seek(to: 90)
        try await wait("拖动进度", model: model) { abs(model.player.currentTime().seconds - 90) < 4 }
        model.togglePlayback()
        try await wait("暂停", seconds: 10, model: model) { !model.isPlaying }
        model.saveProgress()
        let record = LocalLibrary(defaults: defaults).data.history.first
        try require(record?.episode.id == episode.id && (record?.position ?? 0) >= 85, "暂停后历史进度未保存")
        let position = record!.position
        model.stop(); model.resumeMovie()
        try await wait("续播", model: model) { !model.resolving && model.isPlaying && model.player.currentTime().seconds >= position - 2 }
        model.settings.rate = 1.5; model.updateSettings()
        try await wait("倍速", seconds: 10, model: model) { abs(model.player.rate - 1.5) < 0.01 }
        print("PROBE seek/pause/persistence/resume/rate PASS at \(model.player.currentTime().seconds)s, rate=\(model.player.rate)")
        let currentOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        model.player.currentItem!.add(currentOutput)
        var frame: CGImage?
        try await wait("解码视频帧", model: model) {
            let time = currentOutput.itemTime(forHostTime: CACurrentMediaTime())
            if let buffer = currentOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                let image = CIImage(cvPixelBuffer: buffer)
                frame = CIContext().createCGImage(image, from: image.extent)
            }
            return frame != nil
        }
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/probe-frame.png")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: frame!).representation(using: .png, properties: [:])!.write(to: destination)
        print("PROBE decoded frame=\(frame!.width)x\(frame!.height)")
        guard let next = model.nextEpisode else { throw SourceError.invalid("样本缺少下一集") }
        model.play(next, from: 0)
        try await wait("手动下一集", model: model) { model.episode?.id == next.id && !model.resolving && model.isPlaying && model.duration > 0 }
        guard let following = model.nextEpisode else { throw SourceError.invalid("样本缺少第三集") }
        model.seek(to: max(0, model.duration - 2))
        try await wait("自动下一集", seconds: 60, model: model) { model.episode?.id == following.id && !model.resolving && model.isPlaying }
        print("PROBE automatic next -> \(model.episode!.title)")
        model.settings.autoNext = false; model.updateSettings()
        try await wait("第三集时长", model: model) { model.duration > 0 }
        model.seek(to: max(0, model.duration - 2))
        try await wait("关闭自动下一集后停留本集", seconds: 60, model: model) { model.playbackStatus == "本集播放完毕" }
        try require(model.episode?.id == following.id && !model.isPlaying, "关闭自动连播后仍然切集")
        model.togglePlayback()
        try await wait("播完后重新播放", model: model) { model.isPlaying && !model.resolving && model.player.currentTime().seconds < 20 }
        print("PASS: live native playback, seek, pause, saved progress, resume, favorite, 1.5x, manual next, auto-next on/off and replay")
    }
}
