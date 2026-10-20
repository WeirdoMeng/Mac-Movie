import SwiftUI
import AVKit

enum Theme {
    static let accent = Color(red: 0.96, green: 0.73, blue: 0.36)
    static let background = Color(red: 0.045, green: 0.05, blue: 0.065)
    static let surface = Color(red: 0.075, green: 0.085, blue: 0.105)
    static func branded(_ text: String) -> String {
        text.replacingOccurrences(of: "北觅影视", with: "摸鱼视界").replacingOccurrences(of: "北觅", with: "摸鱼视界")
    }
}

struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable().scaledToFit().accessibilityHidden(true)
    }
}

struct ContentView: View {
    @ObservedObject var model: Library
    @FocusState private var searchFocused: Bool
    @ObservedObject var desktop: DesktopController
    var compact = false

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) { compactToolbar; mainContent }
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 170, idealWidth: 180, maxWidth: 210)
                    VStack(spacing: 0) { toolbar; mainContent }
                        .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .task { if model.page.movies.isEmpty { model.load() } }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("重试") { model.retry() }
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭错误提示")
                    }.padding(12).background(Theme.accent.opacity(0.1)).padding(.horizontal, 24).padding(.bottom, 12)
                }
                if model.showDetail {
                    if model.detailLoading { Spacer(); ProgressView("正在读取影片详情…"); Spacer() }
                    else if let detail = model.detail { DetailView(model: model, desktop: desktop, detail: detail, compact: compact) }
                    else { EmptyState(title: "影片暂时无法打开", message: "请返回片库重新选择影片。", icon: "exclamationmark.bubble") }
                } else { CatalogView(model: model, compact: compact) }
                if !model.showDetail, let episode = model.episode, let detail = model.detail {
                    miniPlayer(detail.movie, episode: episode)
                }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if model.showDetail {
                    Button { model.showDetail = false } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回片库")
                } else { AppIconView().frame(width: 25, height: 25) }
                Text(model.showDetail ? "影片详情" : "摸鱼视界").font(.headline)
                Spacer(minLength: 0)
                Menu {
                    ForEach(BrowseSection.all) { section in Button(section.title) { model.navigate(section) } }
                    Divider()
                    Button("设置") { desktop.showSettings = true }
                } label: { Image(systemName: "line.3.horizontal") }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("导航菜单")
                Button { desktop.showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).accessibilityLabel("设置")
            }
            HStack(spacing: 8) {
                TextField("搜索电影、电视剧", text: $model.query).textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { model.search() }
                Button { model.search() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索")
            }
            if !model.showDetail {
                CategoryScroll {
                    HStack(spacing: 6) {
                        ForEach(BrowseSection.all) { section in
                            Button { model.navigate(section) } label: {
                                Text(section.id == "home" ? "首页" : section.title)
                                    .font(.callout).padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(model.section.id == section.id && model.searchTerm.isEmpty ? Theme.accent.opacity(0.18) : .white.opacity(0.04), in: Capsule())
                                    .foregroundStyle(model.section.id == section.id && model.searchTerm.isEmpty ? Theme.accent : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 38)
                HStack { Text(model.title).font(.headline).lineLimit(1); Spacer() }
            }
        }.padding(compact ? 14 : 22).background(Theme.surface)
            .onChange(of: desktop.focusSearch) { _ in searchFocused = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                AppIconView().frame(width: 30, height: 30)
                Text("摸鱼视界").font(.headline)
            }.padding(.top, 15)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(BrowseSection.all.enumerated()), id: \.element.id) { index, section in
                        if index == 5 { Text("内容分类").font(.caption).foregroundStyle(.secondary).padding(.top, 20).padding(.bottom, 6) }
                        Button { model.navigate(section) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.icon).frame(width: 18)
                                Text(section.title)
                                Spacer(minLength: 0)
                                if section.id == "favorites" && !model.favorites.isEmpty { Text("\(model.favorites.count)").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.horizontal, 11).padding(.vertical, 11)
                                .background(model.section.id == section.id && model.searchTerm.isEmpty ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(model.section.id == section.id && model.searchTerm.isEmpty ? Theme.accent : .primary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            Button { desktop.showSettings = true } label: { Label("设置", systemImage: "slider.horizontal.3") }.buttonStyle(.plain).padding(.bottom, 8)
            Text("摸鱼视界 · 随时发现好片").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).background(Theme.surface)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if model.showDetail {
                Button { model.showDetail = false } label: { Image(systemName: "chevron.left") }.help("返回片库").accessibilityLabel("返回片库")
            }
            Text(model.showDetail ? "正在观影" : model.title).font(.title2.bold()).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索影片", text: $model.query).textFieldStyle(.plain).focused($searchFocused).onSubmit { model.search() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空搜索")
                }
            }.padding(9).frame(width: 210).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Button("搜索") { model.search() }.disabled(model.loading)
            Button { if !model.showDetail { model.load() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新片库").accessibilityLabel("刷新片库").disabled(model.showDetail || model.section.path == nil && model.searchTerm.isEmpty)
        }.padding(22)
            .onChange(of: desktop.focusSearch) { _ in searchFocused = true }
    }

    private func miniPlayer(_ movie: Movie, episode: Episode) -> some View {
        Group {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(movie.title) · \(episode.title)").font(.caption).lineLimit(1)
                HStack {
                    Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                    Text(PlaybackPolicy.time(model.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("返回播放") { model.showDetail = true }
                    Button { model.stop() } label: { Image(systemName: "xmark") }.accessibilityLabel("停止播放")
                }
            }.padding(12).background(Theme.surface)
        } else {
        HStack(spacing: 14) {
            Image(systemName: "play.rectangle").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(movie.title) · \(episode.title)").font(.headline)
                Text("\(PlaybackPolicy.time(model.position)) / \(PlaybackPolicy.time(model.duration))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(model.isPlaying ? "暂停" : "播放")
            Button("返回播放") { model.showDetail = true }
            Button { model.stop() } label: { Image(systemName: "xmark") }.accessibilityLabel("停止播放")
        }.padding(16).background(Theme.surface)
        }
        }
    }
}

struct CatalogView: View {
    @ObservedObject var model: Library
    var compact = false
    @State private var clearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.showDetail && model.searchTerm.isEmpty {
                if model.section.id == "rank" { rankControls }
                if !model.page.filters.isEmpty { filterControls }
            }
            HStack {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.section.id == "history", !model.history.isEmpty { Button("清空历史") { clearHistory = true } }
                if model.loading { ProgressView().controlSize(.small) }
            }
            if model.loading {
                Spacer(); HStack { Spacer(); ProgressView("正在加载片库…"); Spacer() }; Spacer()
            } else if model.movies.isEmpty {
                EmptyState(title: emptyTitle, message: emptyMessage, icon: model.section.id == "favorites" ? "heart" : "film")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        Color.clear.frame(height: 1).id("top")
                        LazyVStack(spacing: 0) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 100 : 145, maximum: compact ? 190 : 210), spacing: compact ? 12 : 20)], alignment: .leading, spacing: compact ? 18 : 24) {
                            ForEach(Array(model.movies.enumerated()), id: \.element.id) { index, movie in
                                MovieCard(movie: movie, favorite: model.isFavorite(movie),
                                          record: model.history.first { $0.id == movie.id },
                                          rank: model.section.id == "rank" && model.searchTerm.isEmpty ? index + 1 : nil,
                                          showProgress: model.section.id == "history") {
                                    model.select(movie, resume: model.section.id == "history" && model.searchTerm.isEmpty)
                                } favoriteAction: { model.toggleFavorite(movie) }
                                .contextMenu {
                                    Button("查看详情") { model.select(movie) }
                                    Button(model.isFavorite(movie) ? "取消收藏" : "收藏") { model.toggleFavorite(movie) }
                                    if model.history.contains(where: { $0.id == movie.id }) {
                                        Button("继续播放") { model.select(movie, resume: true) }
                                        Button("移除观看记录") { model.removeHistory(movie) }
                                    }
                                }
                            }
                        }.padding(.bottom, 20)
                            if model.section.path != nil || !model.searchTerm.isEmpty { loadMoreFooter }
                        }
                    }.onChange(of: model.currentURL) { _ in proxy.scrollTo("top") }
                }
            }
        }.padding(.horizontal, compact ? 14 : 24).padding(.top, compact ? 10 : 0).padding(.bottom, 18)
            .confirmationDialog("清空本机全部观看历史？", isPresented: $clearHistory) {
                Button("清空历史", role: .destructive) { model.clearHistory() }
            } message: { Text("收藏和播放设置会保留。") }
    }

    private var subtitle: String {
        if !model.searchTerm.isEmpty { return model.page.total.map { "共 \($0) 部影片" } ?? "搜索结果 · \(model.movies.count) 部影片" }
        if model.section.id == "history" { return "最近观看 · 自动保存播放进度" }
        if model.section.id == "favorites" { return "本机收藏 · \(model.favorites.count) 部影片" }
        if model.section.id == "latest" { return "网站最近 100 个更新" }
        if model.section.id == "rank" { return "摸鱼视界 · \(model.rankPeriod)" }
        return model.page.total.map { "共 \($0) 部影片" } ?? "摸鱼视界 · 为下一次观影找点灵感"
    }
    private var emptyTitle: String { model.section.id == "favorites" ? "收藏喜欢的影片" : model.section.id == "history" ? "还没有观看记录" : "没有找到影片" }
    private var emptyMessage: String { model.section.id == "favorites" ? "点击海报或详情页的爱心，下次在这里找到它。" : model.section.id == "history" ? "开始播放后，这里会记录集数和进度。" : "试试其他关键词或筛选条件，也可以刷新重试。" }

    private var filterControls: some View {
        ViewThatFits(in: .horizontal) {
            filterRow
            ScrollView(.horizontal, showsIndicators: false) { filterRow }
        }
    }
    private var filterRow: some View {
        HStack(spacing: 9) {
            ForEach(model.page.filters) { group in
                Menu {
                    ForEach(group.options) { option in
                        Button { model.load(option.url) } label: {
                            if option.selected { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                        }
                    }
                } label: { Text("\(group.title)：\(group.options.first(where: \.selected)?.title ?? "全部")").font(.callout) }
            }
        }.disabled(model.loading)
    }

    private var rankControls: some View {
        (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
            Picker("榜单", selection: Binding(get: { model.rankPeriod }, set: { model.setRankPeriod($0) })) {
                ForEach(["总榜", "月榜", "周榜"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).frame(width: 220)
            if !model.page.rankSections.isEmpty {
                Picker("分类", selection: $model.rankSection) {
                    ForEach(model.page.rankSections.indices, id: \.self) { index in Text(model.page.rankSections[index].0).tag(index) }
                }.frame(width: 180)
            }
        }.disabled(model.loading)
    }

    private var loadMoreFooter: some View {
        Group {
            if let message = model.loadMoreError {
                VStack(spacing: 8) {
                    Text("加载失败：\(message)").font(.caption).foregroundStyle(.secondary)
                    Button("重试加载") { model.loadMore() }
                }
            } else if model.page.next != nil {
                ProgressView("正在加载更多…")
                    .onAppear { model.loadMore() }
                    .id(model.page.next)
            } else {
                Text("已加载全部影片").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

struct MovieCard: View {
    let movie: Movie
    let favorite: Bool
    let record: WatchRecord?
    let rank: Int?
    let showProgress: Bool
    let select: () -> Void
    let favoriteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: select) {
                GeometryReader { geometry in
                    AsyncImage(url: movie.poster) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Rectangle().fill(.white.opacity(0.06)).overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)) }
                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        if !movie.remark.isEmpty { Text(movie.remark).font(.caption2).padding(7).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.65)) }
                    }
                    .overlay(alignment: .topLeading) {
                        if let rank { Text(String(format: "%02d", rank)).font(.headline.monospacedDigit()).padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6)).padding(7) }
                        else if !movie.score.isEmpty { Text(movie.score).font(.caption.bold()).foregroundStyle(Theme.accent).padding(7).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6)).padding(7) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).accessibilityLabel("查看\(movie.title)")
            HStack(alignment: .top) {
                Button(action: select) { Text(movie.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                Button(action: favoriteAction) { Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? Theme.accent : .secondary) }.buttonStyle(.plain).accessibilityLabel(favorite ? "取消收藏\(movie.title)" : "收藏\(movie.title)")
            }
            if showProgress, let record {
                Text("\(record.episode.title) · \(record.completed ? "已看完" : PlaybackPolicy.time(record.position))").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: record.progress).tint(Theme.accent)
            }
        }
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let icon: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    @ObservedObject var model: Library
    var body: some View {
        Form {
            Section("播放偏好") {
                Toggle("播完自动播放下一集", isOn: $model.settings.autoNext)
                Picker("播放速度", selection: $model.settings.rate) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g") 倍速").tag($0) }
                }
                Toggle("静音", isOn: $model.settings.muted)
                Slider(value: $model.settings.volume, in: 0...1) { Text("音量") }
            }
            Section("本机资料") {
                Text("收藏 \(model.favorites.count) 部 · 历史 \(model.history.count) 部")
                Text("每 5 秒保存一次进度；切集、暂停和退出时保存。收藏、历史和播放偏好保存在本机，不与网站账号同步。").font(.caption).foregroundStyle(.secondary)
            }
            Section("快捷操作") {
                Text("窗口和快捷键均可在对应标签页设置，修改后立即生效。").font(.callout)
            }
        }.formStyle(.grouped).frame(width: 460, height: 430)
            .onChange(of: model.settings) { _ in model.updateSettings() }
    }
}
