import SwiftUI
import AVKit

@MainActor
final class Library: ObservableObject {
    @Published var page = CatalogPage()
    @Published var detail: MovieDetail?
    @Published var episode: Episode?
    @Published var query = ""
    @Published var section = BrowseSection.all[0]
    @Published var showDetail = false
    @Published var loading = false
    @Published var loadingMore = false
    @Published var loadMoreError: String?
    @Published var detailLoading = false
    @Published var resolving = false
    @Published var error: String?
    @Published var playbackStatus = "选择剧集开始播放"
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var favorites: [Movie]
    @Published var history: [WatchRecord]
    @Published var settings: PlayerSettings
    @Published var selectedLine = ""
    @Published var reverseEpisodes = false
    @Published var rankSection = 0
    @Published var rankPeriod = "总榜"
    @Published var searchTerm = ""
    let player = AVPlayer()
    private let source = Beimi()
    private let loadPage: (URL) async throws -> CatalogPage
    private var loadedPages = Set<URL>()
    private let local: LocalLibrary
    private(set) var currentURL = Beimi.base
    private var catalogTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var preferenceObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var terminationObserver: NSObjectProtocol?
    private var catalogGeneration = UUID()
    private var detailGeneration = UUID()
    private var playGeneration = UUID()
    private var lastSave = Date.distantPast
    private var playbackFailed = false
    private var playbackEnded = false
    private var requiresManualPlayback = false
    private var detailMovie: Movie?

    init(defaults: UserDefaults = .standard, pageLoader: ((URL) async throws -> CatalogPage)? = nil) {
        loadPage = pageLoader ?? { try await Beimi().page($0) }
        local = LocalLibrary(defaults: defaults)
        favorites = local.data.favorites
        history = local.data.history
        settings = local.data.settings
        error = local.readError
        player.volume = settings.volume; player.isMuted = settings.muted
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePlaybackStatus() }
        }
        preferenceObservations = [
            player.observe(\.volume, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.settings.volume != self.player.volume else { return }
                    self.settings.volume = self.player.volume; self.persist()
                }
            },
            player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.settings.muted != self.player.isMuted else { return }
                    self.settings.muted = self.player.isMuted; self.persist()
                }
            },
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(self.player.rate),
                          self.settings.rate != self.player.rate else { return }
                    self.settings.rate = self.player.rate; self.persist()
                }
            }
        ]
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProgress() }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        catalogTask?.cancel(); detailTask?.cancel(); playTask?.cancel(); timeoutTask?.cancel()
    }

    var movies: [Movie] {
        if searchTerm.isEmpty && section.id == "favorites" { return favorites }
        if searchTerm.isEmpty && section.id == "history" { return history.map(\.movie) }
        if section.id == "rank", page.rankSections.indices.contains(rankSection) { return page.rankSections[rankSection].1 }
        return page.movies
    }
    var title: String { searchTerm.isEmpty ? section.title : "“\(searchTerm)”的搜索结果" }
    var nextEpisode: Episode? { episode.flatMap { PlaybackPolicy.adjacent(to: $0, in: detail?.episodes ?? [], offset: 1) } }
    var previousEpisode: Episode? { episode.flatMap { PlaybackPolicy.adjacent(to: $0, in: detail?.episodes ?? [], offset: -1) } }
    var visibleEpisodes: [Episode] {
        let list = PlaybackPolicy.ordered(detail?.episodes ?? [], line: selectedLine)
        return reverseEpisodes ? list.reversed() : list
    }
    var lineIDs: [String] { Array(Set(detail?.episodes.map(\.line) ?? [])).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } }

    func navigate(_ section: BrowseSection) {
        self.section = section; showDetail = false; query = ""; searchTerm = ""; rankSection = 0; rankPeriod = "总榜"
        if let path = section.path { load(URL(string: path, relativeTo: Beimi.base)!.absoluteURL) }
        else { catalogTask?.cancel(); catalogGeneration = UUID(); loading = false; loadingMore = false; loadMoreError = nil; loadedPages = []; page = CatalogPage(); error = nil }
    }

    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { navigate(section); return }
        searchTerm = term; showDetail = false; rankSection = 0
        load(Beimi.searchURL(term))
    }

    func load(_ url: URL? = nil) {
        let url = url ?? currentURL
        catalogTask?.cancel()
        let generation = UUID(); catalogGeneration = generation
        loading = true; loadingMore = false; loadMoreError = nil; loadedPages = [url]; error = nil; currentURL = url
        catalogTask = Task {
            do {
                let result = try await loadPage(url)
                guard !Task.isCancelled, catalogGeneration == generation else { return }
                page = result; rankSection = 0
            } catch {
                guard !Task.isCancelled, catalogGeneration == generation else { return }
                self.error = error.localizedDescription
            }
            if catalogGeneration == generation { loading = false }
        }
    }

    func loadMore() {
        guard !loading, !loadingMore, let url = page.next, !loadedPages.contains(url),
              section.path != nil || !searchTerm.isEmpty else { return }
        let generation = catalogGeneration
        loadingMore = true; loadMoreError = nil
        catalogTask = Task {
            do {
                let result = try await loadPage(url)
                guard !Task.isCancelled, catalogGeneration == generation else { return }
                loadedPages.insert(url)
                var ids = Set(page.movies.map(\.id))
                page.movies.append(contentsOf: result.movies.filter { ids.insert($0.id).inserted })
                page.pageNumber = result.pageNumber
                page.pageCount = result.pageCount
                page.next = result.next.flatMap { loadedPages.contains($0) ? nil : $0 }
            } catch {
                guard !Task.isCancelled, catalogGeneration == generation else { return }
                loadMoreError = error.localizedDescription
            }
            if catalogGeneration == generation { loadingMore = false }
        }
    }

    func setRankPeriod(_ title: String) {
        rankPeriod = title
        let path = title == "月榜" ? "/label/rankmonth.html" : title == "周榜" ? "/label/rankweek.html" : "/label/rank/"
        load(URL(string: path, relativeTo: Beimi.base)!.absoluteURL)
    }

    func select(_ movie: Movie, resume: Bool = false) {
        requiresManualPlayback = false
        if detail?.movie.id == movie.id {
            showDetail = true
            if resume { resumeMovie() }
            return
        }
        detailTask?.cancel(); stop()
        detailMovie = movie
        let generation = UUID(); detailGeneration = generation
        detail = nil; showDetail = true; detailLoading = true; error = nil
        detailTask = Task {
            do {
                let result = try await source.detail(movie)
                guard !Task.isCancelled, detailGeneration == generation else { return }
                detail = result; selectedLine = result.episodes.first?.line ?? ""
                if resume && !requiresManualPlayback { resumeMovie() }
            } catch {
                guard !Task.isCancelled, detailGeneration == generation else { return }
                self.error = error.localizedDescription
            }
            if detailGeneration == generation { detailLoading = false }
        }
    }

    func stop() {
        saveProgress()
        playTask?.cancel(); timeoutTask?.cancel(); playGeneration = UUID()
        observation = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers = []
        player.pause(); player.replaceCurrentItem(with: nil)
        episode = nil; resolving = false; isPlaying = false; position = 0; duration = 0
        playbackFailed = false; playbackEnded = false
        playbackStatus = "选择剧集开始播放"
    }

    func play(_ selected: Episode, from start: Double? = nil) {
        requiresManualPlayback = false
        saveProgress()
        let saved = history.first { $0.id == detail?.movie.id }
        let resume = start ?? PlaybackPolicy.resumePosition(saved, episode: selected)
        stop(); error = nil; episode = selected; selectedLine = selected.line; resolving = true
        playbackStatus = "正在获取播放地址…"
        let generation = UUID(); playGeneration = generation
        playTask = Task {
            do {
                let url = try await source.resolve(selected)
                guard !Task.isCancelled, playGeneration == generation else { return }
                let item = AVPlayerItem(url: url)
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playGeneration == generation else { return }
                        if item.status == .readyToPlay {
                            self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                            if resume > 0 {
                                let target = self.duration > 0 ? min(resume, max(0, self.duration - 5)) : resume
                                _ = await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                            }
                            guard self.playGeneration == generation else { return }
                            self.resolving = false; self.timeoutTask?.cancel()
                            if !self.requiresManualPlayback { self.player.playImmediately(atRate: self.settings.rate) }
                            self.saveProgress(); self.updatePlaybackStatus()
                        } else if item.status == .failed { self.fail(item.error?.localizedDescription ?? "播放器无法打开此资源。") }
                    }
                }
                notificationObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                    let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "视频播放中断，请重试或选择其他线路。"
                    Task { @MainActor [weak self] in
                        guard let self, self.playGeneration == generation else { return }; self.fail(message)
                    }
                })
                notificationObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playGeneration == generation else { return }
                        self.saveProgress(completed: true)
                        if self.settings.autoNext, !self.requiresManualPlayback, let next = self.nextEpisode { self.play(next, from: 0) }
                        else { self.playbackEnded = true; self.isPlaying = false; self.playbackStatus = "本集播放完毕" }
                    }
                })
                player.replaceCurrentItem(with: item)
                player.volume = settings.volume; player.isMuted = settings.muted
                playbackStatus = "正在缓冲 · \(selected.title)"
                if !requiresManualPlayback { player.playImmediately(atRate: settings.rate) }
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard !Task.isCancelled, let self, self.playGeneration == generation, self.resolving else { return }
                    self.fail("缓冲超过 45 秒，请重试或切换线路。")
                }
            } catch {
                guard !Task.isCancelled, playGeneration == generation else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        playbackFailed = true
        resolving = false; isPlaying = false; timeoutTask?.cancel(); player.pause()
        playbackStatus = "播放失败"; error = message
    }

    func resumeMovie() {
        guard let detail else { return }
        let saved = history.first { $0.id == detail.movie.id }
        let target = detail.episodes.first { $0.id == saved?.episode.id } ?? detail.episodes.first
        if let target { play(target) }
    }

    func switchLine(_ line: String) {
        guard selectedLine != line else { return }
        selectedLine = line
        guard let episode else { return }
        if let equivalent = PlaybackPolicy.equivalent(episode, line: line, episodes: detail?.episodes ?? []) {
            play(equivalent, from: position)
        } else { error = "该线路没有对应集数，请在下方选集。" }
    }

    func pauseForHiding() {
        // Also suppress the ready-to-play callback if the stream is still loading.
        requiresManualPlayback = true
        player.pause()
        isPlaying = false
        if let episode, !resolving, !playbackEnded, !playbackFailed { playbackStatus = "已暂停 · \(episode.title)" }
        saveProgress()
    }

    func togglePlayback() {
        guard episode != nil, !resolving else { return }
        requiresManualPlayback = false
        if playbackEnded, let episode { play(episode, from: 0); return }
        if player.timeControlStatus == .paused { player.playImmediately(atRate: settings.rate) }
        else { player.pause(); saveProgress() }
    }

    func seek(to seconds: Double) {
        guard episode != nil, !resolving else { return }
        playbackEnded = false
        player.seek(to: CMTime(seconds: max(0, min(duration > 0 ? duration : seconds, seconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    func updateSettings() {
        settings.rate = [0.5, 0.75, 1, 1.25, 1.5, 2].contains(settings.rate) ? settings.rate : 1
        settings.volume = min(1, max(0, settings.volume))
        player.volume = settings.volume; player.isMuted = settings.muted
        if player.rate != 0 { player.rate = settings.rate }
        persist()
    }

    private func updatePlaybackStatus() {
        guard let episode, !resolving, !playbackFailed, !playbackEnded else { return }
        isPlaying = player.timeControlStatus == .playing
        if isPlaying { requiresManualPlayback = false }
        if player.currentItem?.status == .failed { return }
        switch player.timeControlStatus {
        case .playing: playbackStatus = "正在播放 · \(episode.title)"
        case .waitingToPlayAtSpecifiedRate: playbackStatus = "正在缓冲 · \(episode.title)"
        case .paused: playbackStatus = "已暂停 · \(episode.title)"; saveProgress()
        @unknown default: break
        }
    }

    private func tick() {
        guard let item = player.currentItem else { return }
        let time = player.currentTime().seconds
        if time.isFinite { position = max(0, time) }
        if item.duration.seconds.isFinite { duration = max(0, item.duration.seconds) }
        if Date().timeIntervalSince(lastSave) >= 5 { saveProgress() }
    }

    func saveProgress(completed: Bool = false) {
        guard let movie = detail?.movie, let episode, player.currentItem?.status == .readyToPlay else { return }
        let time = player.currentTime().seconds
        let seconds = time.isFinite ? max(0, time) : position
        let length = player.currentItem?.duration.seconds ?? duration
        let record = WatchRecord(movie: movie, episode: episode, position: completed && length.isFinite ? length : seconds,
                                 duration: length.isFinite ? max(0, length) : 0, updatedAt: Date())
        history.removeAll { $0.id == movie.id }; history.insert(record, at: 0)
        history = Array(history.prefix(200)); lastSave = Date(); persist()
    }

    func isFavorite(_ movie: Movie) -> Bool { favorites.contains { $0.id == movie.id } }
    func toggleFavorite(_ movie: Movie) {
        if isFavorite(movie) { favorites.removeAll { $0.id == movie.id } }
        else { favorites.insert(movie, at: 0) }
        persist()
    }
    func removeHistory(_ movie: Movie) { history.removeAll { $0.id == movie.id }; persist() }
    func clearHistory() { history = []; persist() }
    func retry() {
        if showDetail, let episode { play(episode, from: position) }
        else if showDetail, let detailMovie { select(detailMovie) }
        else { load() }
    }
    private func persist() {
        do { try local.save(SavedLibrary(favorites: favorites, history: history, settings: settings)) }
        catch { self.error = "本地记录保存失败：\(error.localizedDescription)" }
    }
}
