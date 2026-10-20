import SwiftUI
import AVKit

struct DetailView: View {
    @ObservedObject var model: Library
    @ObservedObject var desktop: DesktopController
    let detail: MovieDetail
    var compact = false
    @State private var sliderPosition: Double = 0
    @State private var dragging = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                heading
                ZStack {
                    NativePlayer(player: model.player, windowFill: { desktop.perform(.windowFill) })
                    if model.episode == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "play.circle").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Theme.accent)
                            Button(resumeTitle) { model.resumeMovie() }.buttonStyle(.borderedProminent).disabled(detail.episodes.isEmpty)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    } else if model.resolving {
                        ProgressView("准备播放…").padding(18).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.aspectRatio(16 / 9, contentMode: .fit).frame(maxHeight: 460).clipShape(RoundedRectangle(cornerRadius: 12))
                controls
                Divider()
                episodes
                Divider()
                Text("影片信息").font(.title3.bold())
                Text(Theme.branded(detail.metadata)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text(detail.summary.isEmpty ? "暂无剧情简介" : Theme.branded(detail.summary)).font(.callout).lineSpacing(6).textSelection(.enabled)
                if !detail.recommendations.isEmpty { recommendations }
            }.padding(.horizontal, compact ? 14 : 24).padding(.bottom, 30)
        }.onChange(of: model.position) { if !dragging { sliderPosition = $0 } }
            .onChange(of: model.episode?.id) { _ in sliderPosition = 0 }
    }

    private var resumeTitle: String {
        guard let record = model.history.first(where: { $0.id == detail.movie.id }), !record.completed else { return "开始播放" }
        return "继续 \(record.episode.title) · \(PlaybackPolicy.time(record.position))"
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.movie.title).font(compact ? .title2.bold() : .largeTitle.bold()).textSelection(.enabled)
                Text(detail.movie.remark).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.toggleFavorite(detail.movie) } label: {
                Label(model.isFavorite(detail.movie) ? "已收藏" : "收藏", systemImage: model.isFavorite(detail.movie) ? "heart.fill" : "heart")
            }
            ShareLink(item: Beimi.base.appendingPathComponent("voddetail/\(detail.movie.id).html")) { Image(systemName: "square.and.arrow.up") }.help("分享影片页面")
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(PlaybackPolicy.time(dragging ? sliderPosition : model.position)).font(.caption.monospacedDigit()).frame(width: 58)
                Slider(value: $sliderPosition, in: 0...max(1, model.duration)) { editing in
                    dragging = editing
                    if !editing { model.seek(to: sliderPosition) }
                }.disabled(model.episode == nil || model.duration <= 0 || model.resolving).accessibilityLabel("播放进度")
                Text(PlaybackPolicy.time(model.duration)).font(.caption.monospacedDigit()).frame(width: 58)
            }
            ViewThatFits(in: .horizontal) {
                HStack { transportControls; speedControls }
                VStack(alignment: .leading, spacing: 12) { transportControls; speedControls }
            }
            HStack {
                Text(model.playbackStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let episode = model.episode {
                    Button("从头播放") { model.play(episode, from: 0) }
                    Button("重试") { model.play(episode, from: model.position) }
                }
            }
        }.onChange(of: model.settings) { _ in model.updateSettings() }
    }

    private var transportControls: some View {
            HStack(spacing: compact ? 12 : 14) {
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(model.isPlaying ? "暂停" : "播放").disabled(model.episode == nil || model.resolving)
                Button { model.seek(to: model.position - 10) } label: { Image(systemName: "gobackward.10") }.help("后退 10 秒").accessibilityLabel("后退 10 秒").disabled(model.episode == nil || model.resolving)
                Button { model.seek(to: model.position + 10) } label: { Image(systemName: "goforward.10") }.help("前进 10 秒").accessibilityLabel("前进 10 秒").disabled(model.episode == nil || model.resolving)
                Button { if let previous = model.previousEpisode { model.play(previous) } } label: { Image(systemName: "backward.end") }.help("上一集").accessibilityLabel("上一集").disabled(model.previousEpisode == nil)
                Button { if let next = model.nextEpisode { model.play(next, from: 0) } } label: { Image(systemName: "forward.end") }.help("下一集").accessibilityLabel("下一集").disabled(model.nextEpisode == nil)
                Spacer(minLength: 0)
                Button { desktop.perform(.windowFill) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("窗口全屏").accessibilityLabel("窗口全屏")
            }.buttonStyle(.borderless)
    }

    private var speedControls: some View {
            HStack {
                Picker("倍速", selection: $model.settings.rate) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }.labelsHidden().frame(width: 78)
                Toggle("自动下一集", isOn: $model.settings.autoNext).toggleStyle(.checkbox).font(.caption)
            }.fixedSize(horizontal: true, vertical: false)
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选集").font(.title3.bold())
                Text("\(model.visibleEpisodes.count) 集").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.reverseEpisodes ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") { model.reverseEpisodes.toggle() }
            }
                if model.lineIDs.count > 1 {
                    Picker("线路", selection: Binding(get: { model.selectedLine }, set: { model.switchLine($0) })) {
                        ForEach(model.lineIDs, id: \.self) { id in Text(Theme.branded(detail.lines[id] ?? "线路 \(id)")).tag(id) }
                    }.frame(maxWidth: 230)
                } else { Text(Theme.branded(detail.lines[model.selectedLine] ?? "")).font(.caption).foregroundStyle(.secondary) }
            if model.visibleEpisodes.isEmpty { Text("当前线路没有可识别的剧集。").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                ForEach(model.visibleEpisodes) { episode in
                    Button { model.play(episode) } label: {
                        Text(episode.title).font(.callout).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(model.episode?.id == episode.id ? Theme.accent.opacity(0.22) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(model.episode?.id == episode.id ? Theme.accent : .primary)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("相关推荐").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(detail.recommendations) { movie in
                        MovieCard(movie: movie, favorite: model.isFavorite(movie), record: nil, rank: nil, showProgress: false) {
                            model.select(movie)
                        } favoriteAction: { model.toggleFavorite(movie) }.frame(width: 135)
                    }
                }.padding(.bottom, 8)
            }
        }
    }
}

final class KeyboardPlayerView: AVPlayerView {
    var windowFill: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    // Application shortcuts are dispatched centrally so rebinding removes the old key.
    override func keyDown(with event: NSEvent) { nextResponder?.keyDown(with: event) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { windowFill?(); return }
        super.mouseDown(with: event)
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    let windowFill: () -> Void
    func makeNSView(context: Context) -> KeyboardPlayerView {
        let view = KeyboardPlayerView()
        view.player = player; view.controlsStyle = .floating; view.showsFullScreenToggleButton = false
        view.windowFill = windowFill
        return view
    }
    func updateNSView(_ view: KeyboardPlayerView, context: Context) {
        view.player = player; view.windowFill = windowFill
    }
}
