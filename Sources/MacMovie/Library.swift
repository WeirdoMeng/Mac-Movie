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
    @Published private(set) var playbackFocusRequest = UUID()
    @Published var loading = false
    @Published var loadingMore = false
    @Published var loadMoreError: String?
    @Published var detailLoading = false
    @Published var resolving = false
    @Published var error: String?
    @Published private(set) var playbackDiagnostics: String?
    @Published private(set) var diagnosticsCopied = false
    @Published var playbackStatus = "选择剧集开始播放"
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var favorites: [Movie]
    @Published var history: [WatchRecord]
    @Published var settings: PlayerSettings
    @Published var selectedLine = ""
    @Published var reverseEpisodes = false
    @Published var rankPeriod = "热度"
    @Published var searchTerm = ""
    let player = AVPlayer()
    private let source = Boju()
    private let loadPage: (URL) async throws -> CatalogPage
    private let preferCompatibilityRelay: Bool
    private let retryDeniedMedia: Bool
    private var loadedPages = Set<URL>()
    private let local: LocalLibrary
    private(set) var currentURL = Boju.base
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
    private var currentMediaURL: URL?
    private var mediaRelay: HLSRelay?
    private var webResolver: WebPlaybackResolver?
    private(set) var webEvidence = ""
    private var retriedMediaAccess = false
    private var retriedCoreMedia15628 = false
    private var recoveryTrace: String?
    private var requestedResume: Double = 0
    private var requiresManualPlayback = false
    private var detailMovie: Movie?

    init(defaults: UserDefaults = .standard, pageLoader: ((URL) async throws -> CatalogPage)? = nil, preferCompatibilityRelay: Bool = false, retryDeniedMedia: Bool = true) {
        self.preferCompatibilityRelay = preferCompatibilityRelay
        self.retryDeniedMedia = retryDeniedMedia
        loadPage = pageLoader ?? { try await Boju().page($0) }
        local = LocalLibrary(defaults: defaults)
        favorites = local.data.favorites.filter { $0.id.hasPrefix(Boju.idPrefix) }
        history = local.data.history.filter { $0.id.hasPrefix(Boju.idPrefix) }
        settings = local.data.settings
        error = local.readError
        if local.readError == nil && (favorites.count != local.data.favorites.count || history.count != local.data.history.count) {
            if let previous = defaults.data(forKey: LocalLibrary.key) {
                defaults.set(previous, forKey: LocalLibrary.key + ".previous-source")
            }
            try? local.save(SavedLibrary(favorites: favorites, history: history, settings: settings))
        }
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
        self.section = section; showDetail = false; query = ""; searchTerm = ""; rankPeriod = "热度"
        if let path = section.path { load(URL(string: path, relativeTo: Boju.base)!.absoluteURL) }
        else { catalogTask?.cancel(); catalogGeneration = UUID(); loading = false; loadingMore = false; loadMoreError = nil; loadedPages = []; page = CatalogPage(); error = nil }
    }

    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { navigate(section); return }
        searchTerm = term; showDetail = false
        load(Boju.searchURL(term))
    }

    func clearSearch() {
        query = ""
        if !searchTerm.isEmpty { navigate(section) }
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
                page = result
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
        var components = URLComponents(url: Boju.base.appendingPathComponent("catalog/rank"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "by", value: title == "评分" ? "score" : title == "最新" ? "time" : "hits")]
        load(components.url!)
    }

    func select(_ movie: Movie, resume: Bool = true) {
        playbackFocusRequest = UUID()
        requiresManualPlayback = false
        if detail?.movie.id == movie.id {
            showDetail = true
            if resume && !isPlaying && !resolving { resumeMovie() }
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
                detail = result; selectedLine = PlaybackPolicy.preferredEpisode(in: result)?.line ?? ""
                if result.movie.poster != nil {
                    var changed = false
                    if let index = favorites.firstIndex(where: { $0.id == result.movie.id && $0.poster == nil }) {
                        favorites[index] = result.movie; changed = true
                    }
                    if let index = history.firstIndex(where: { $0.id == result.movie.id && $0.movie.poster == nil }) {
                        let record = history[index]
                        history[index] = WatchRecord(movie: result.movie, episode: record.episode,
                                                     position: record.position, duration: record.duration, updatedAt: record.updatedAt)
                        changed = true
                    }
                    if changed { persist() }
                }
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
        clearItemObservers()
        webResolver?.cancel(); webResolver = nil; webEvidence = ""
        mediaRelay?.stop(); mediaRelay = nil; retriedMediaAccess = false
        retriedCoreMedia15628 = false; recoveryTrace = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        episode = nil; resolving = false; isPlaying = false; position = 0; duration = 0
        playbackFailed = false; playbackEnded = false
        currentMediaURL = nil; playbackDiagnostics = nil; diagnosticsCopied = false
        playbackStatus = "选择剧集开始播放"
    }

    func play(_ selected: Episode, from start: Double? = nil) {
        requiresManualPlayback = false
        saveProgress()
        let saved = history.first { $0.id == detail?.movie.id }
        let resume = start ?? PlaybackPolicy.resumePosition(saved, episode: selected)
        stop(); error = nil; episode = selected; selectedLine = selected.line; resolving = true
        requestedResume = resume
        playbackStatus = "正在通过网页获取播放参数…"
        let generation = UUID(); playGeneration = generation
        playTask = Task {
            do {
                let resolver = WebPlaybackResolver(); webResolver = resolver
                let url = try await resolver.resolve(selected.url)
                webEvidence = resolver.evidence
                webResolver = nil
                guard !Task.isCancelled, playGeneration == generation else { return }
                currentMediaURL = url
                if preferCompatibilityRelay && url.pathExtension.lowercased() == "m3u8" { retryMediaAccess(url, episode: selected) }
                else { installItem(url, selected: selected, resume: resume, generation: generation) }
            } catch {
                guard !Task.isCancelled, playGeneration == generation else { return }
                fail(error.localizedDescription, underlying: error)
            }
        }
    }

    private func installItem(_ url: URL, selected: Episode, resume: Double, generation: UUID) {
        let item = AVPlayerItem(asset: PlaybackNetworking.asset(url))
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.playGeneration == generation, self.player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    if resume > 0 {
                        let target = self.duration > 0 ? min(resume, max(0, self.duration - 5)) : resume
                        _ = await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                    }
                    guard self.playGeneration == generation, self.player.currentItem === item else { return }
                    self.resolving = false; self.timeoutTask?.cancel()
                    if !self.requiresManualPlayback { self.player.playImmediately(atRate: self.settings.rate) }
                    self.saveProgress(); self.updatePlaybackStatus()
                } else if item.status == .failed { self.fail(item.error?.localizedDescription ?? "播放器无法打开此资源。", underlying: item.error) }
            }
        }
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let underlying = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = underlying?.localizedDescription ?? "视频播放中断，请重试或选择其他线路。"
            Task { @MainActor [weak self] in
                guard let self, self.playGeneration == generation, self.player.currentItem === item else { return }; self.fail(message, underlying: underlying)
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playGeneration == generation, self.player.currentItem === item else { return }
                self.saveProgress(completed: true)
                if self.settings.autoNext, !self.requiresManualPlayback, let next = self.nextEpisode { self.play(next, from: 0) }
                else { self.playbackEnded = true; self.isPlaying = false; self.playbackStatus = "本集播放完毕" }
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playGeneration == generation, self.player.currentItem === item, self.playbackFailed else { return }
                self.fail(self.error ?? "视频加载失败。", underlying: self.player.currentItem?.error)
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
    }

    private func fail(_ message: String, underlying: Error? = nil) {
        let actualError = underlying ?? player.currentItem?.error
        var events = player.currentItem?.errorLog()?.events.map { (status: $0.errorStatusCode, uri: $0.uri) } ?? []
        if retryDeniedMedia, !retriedMediaAccess, let url = currentMediaURL, url.pathExtension.lowercased() == "m3u8",
           let episode, PlaybackIssue.isAccessDenied(actualError, statuses: events.map(\.status)) {
            retryMediaAccess(url, episode: episode)
            return
        }
        if !retriedCoreMedia15628, !requiresManualPlayback, let url = currentMediaURL,
           url.pathExtension.lowercased() == "m3u8", let episode,
           !events.contains(where: { (400...499).contains($0.status) }),
           PlaybackIssue.isCoreMedia15628(actualError) {
            let time = player.currentTime().seconds
            let resume = time.isFinite && time > 0 ? time : (position > 0 ? position : requestedResume)
            play(episode, from: resume)
            retriedCoreMedia15628 = true
            recoveryTrace = "自动恢复：重新获取播放参数一次；位置：\(Int(resume)) 秒；错误：CoreMediaErrorDomain / -15628"
            playbackStatus = "正在自动重试 · \(episode.title)"
            return
        }
        playbackFailed = true
        resolving = false; isPlaying = false; timeoutTask?.cancel(); player.pause()
        let trace = mediaRelay?.events.map { "兼容请求：\($0.kind) / \($0.status) / \($0.host)" } ?? []
        events.append(contentsOf: mediaRelay?.events.map { (status: $0.status, uri: "https://" + $0.host) } ?? [])
        var diagnosticTrace = [webEvidence, recoveryTrace].compactMap { $0 }.filter { !$0.isEmpty } + trace
        if let relayError = mediaRelay?.lastError as NSError? { diagnosticTrace.append("兼容错误：\(relayError.domain) / \(relayError.code)") }
        let issue = PlaybackIssue(error: actualError, fallback: message, mediaURL: currentMediaURL, events: events,
                                  transport: retriedMediaAccess ? "WebView 参数 + HLS 兼容重试，无 Referer" : "WebView 参数 + 原生播放，无 Referer", trace: diagnosticTrace)
        playbackStatus = "播放失败"; error = issue.message
        playbackDiagnostics = issue.diagnostics; diagnosticsCopied = false
        mediaRelay?.stop()
    }

    private func clearItemObservers() {
        observation = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers = []
    }

    private func retryMediaAccess(_ url: URL, episode: Episode) {
        retriedMediaAccess = true
        let time = player.currentTime().seconds
        let resume = time.isFinite && time > 0 ? time : requestedResume
        let generation = playGeneration
        timeoutTask?.cancel(); playTask?.cancel(); clearItemObservers(); player.pause()
        player.replaceCurrentItem(with: nil)
        playbackFailed = false; isPlaying = false; resolving = true; error = nil
        playbackStatus = "正在重试兼容播放…"
        let relay = HLSRelay(root: url); mediaRelay = relay
        playTask = Task {
            do {
                let localURL = try await relay.start()
                guard !Task.isCancelled, playGeneration == generation else { relay.stop(); return }
                installItem(localURL, selected: episode, resume: resume, generation: generation)
            } catch {
                guard !Task.isCancelled, playGeneration == generation else { return }
                fail("兼容播放请求失败，请复制诊断反馈。", underlying: error)
            }
        }
    }

    func copyPlaybackDiagnostics() {
        guard let playbackDiagnostics else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(playbackDiagnostics, forType: .string)
        diagnosticsCopied = true
    }

    func resumeMovie() {
        guard let detail else { return }
        let saved = history.first { $0.id == detail.movie.id }
        let target = detail.episodes.first { $0.id == saved?.episode.id } ?? PlaybackPolicy.preferredEpisode(in: detail)
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
        if playbackEnded, let episode { play(episode, from: 0); return }
        if player.timeControlStatus == .paused {
            requiresManualPlayback = false
            player.playImmediately(atRate: settings.rate)
        } else {
            requiresManualPlayback = true
            player.pause(); saveProgress()
        }
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
