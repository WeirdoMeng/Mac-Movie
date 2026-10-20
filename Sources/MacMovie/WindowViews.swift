import SwiftUI
import AVKit

struct MovieRootView: View {
    @ObservedObject var model: Library
    @ObservedObject var desktop: DesktopController
    var body: some View {
        GeometryReader { geometry in
            if desktop.windowFill && model.detail != nil {
                WindowPlayerView(model: model, desktop: desktop)
            } else { ContentView(model: model, desktop: desktop, compact: geometry.size.width < 880 || geometry.size.height < 540) }
        }
        .background(Theme.background)
        .overlay(alignment: .top) { if desktop.preferences.borderless { WindowDragStrip().frame(height: 10) } }
        .overlay(alignment: .bottomTrailing) { WindowResizeHandle().frame(width: 18, height: 18).padding(3) }
        .sheet(isPresented: $desktop.showSettings) {
            VStack(spacing: 0) {
                HStack { Text("设置").font(.headline); Spacer(); Button("完成") { desktop.showSettings = false } }.padding()
                AppPreferencesView(model: model, desktop: desktop)
            }.onDisappear { desktop.shortcuts.cancelRecording() }
        }
    }
}

struct WindowPlayerView: View {
    @ObservedObject var model: Library
    @ObservedObject var desktop: DesktopController
    @State private var hovered = false
    var body: some View {
        ZStack {
            NativePlayer(player: model.player, windowFill: { desktop.perform(.windowFill) })
            if model.episode == nil {
                VStack(spacing: 12) {
                    AppIconView().frame(width: 42, height: 42)
                    Text(model.detail?.movie.title ?? "摸鱼视界").font(.headline).lineLimit(1)
                    if model.detail != nil { Button("开始播放") { model.resumeMovie() } }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            }
            if model.resolving { ProgressView().padding().background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)) }
            VStack {
                HStack(spacing: 10) {
                    WindowDragStrip().frame(minWidth: 20, maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                    if let episode = model.episode { Text(episode.title).font(.caption).lineLimit(1) }
                    Button { desktop.browse() } label: { Image(systemName: "rectangle.grid.2x2") }.help("返回浏览").accessibilityLabel("返回浏览")
                    Button { desktop.windowFill = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.help("退出窗口全屏（Esc）").accessibilityLabel("退出窗口全屏")
                    Menu {
                        Button("设置") { desktop.showSettings = true }
                        Button(desktop.preferences.borderless ? "恢复边框" : "无边框") { desktop.perform(.borderless) }
                        Button(desktop.preferences.pinned ? "取消置顶" : "窗口置顶") { desktop.perform(.pin) }
                        Button("隐藏窗口") { desktop.toggleVisibility() }
                        Button("系统全屏") { desktop.perform(.systemFullScreen) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22).help("窗口选项")
                }.padding(9).background(.black.opacity(0.55))
                    .opacity(hovered || model.episode == nil ? 1 : 0)
                    .allowsHitTesting(hovered || model.episode == nil)
                Spacer()
                if let error = model.error {
                    HStack {
                        Text(error).font(.caption).lineLimit(3)
                        Button("重试") { model.retry() }
                    }.padding(10).background(.black.opacity(0.75))
                }
            }.foregroundStyle(.white)
        }.background(.black).onHover { hovered = $0 }
            .contextMenu {
                Button("返回浏览") { desktop.browse() }
                Button("设置") { desktop.showSettings = true }
                Button(desktop.preferences.borderless ? "恢复边框" : "无边框") { desktop.perform(.borderless) }
                Button("隐藏窗口") { desktop.toggleVisibility() }
            }
    }
}

struct AppPreferencesView: View {
    @ObservedObject var model: Library
    @ObservedObject var desktop: DesktopController
    var body: some View {
        TabView {
            SettingsView(model: model).tabItem { Label("播放", systemImage: "play.circle") }
            windowSettings.tabItem { Label("窗口", systemImage: "macwindow") }
            ShortcutSettingsView(manager: desktop.shortcuts).tabItem { Label("快捷键", systemImage: "keyboard") }
        }.padding(12).frame(width: 640, height: 560)
    }
    private var windowSettings: some View {
        Form {
            Section("窗口外观 · 即时生效") {
                Toggle("无边框", isOn: $desktop.preferences.borderless)
                Toggle("窗口置顶", isOn: $desktop.preferences.pinned)
                HStack {
                    Text("窗口不透明度")
                    Slider(value: $desktop.preferences.opacity, in: 0.1...1, step: 0.05)
                    Text("\(Int((desktop.preferences.opacity * 100).rounded()))%").monospacedDigit().frame(width: 45)
                }
                Button("恢复不透明") { desktop.preferences.opacity = 1 }
            }
            Section("观看方式") {
                Toggle("窗口全屏：视频铺满当前窗口", isOn: $desktop.windowFill)
                Text("窗口全屏保留窗口的位置与尺寸，不切换桌面。Esc 可退出；系统全屏可从“窗口”菜单单独开启。").font(.caption).foregroundStyle(.secondary)
            }
            Section("自由调整大小") {
                HStack {
                    Button("缩小窗口") { desktop.resize(1 / 1.12) }
                    Button("放大窗口") { desktop.resize(1.12) }
                    Button("恢复片库尺寸") { desktop.openLibrary() }
                }
                Text("拖动窗口边缘或右下角可自由缩放，不锁定宽高比；小窗口使用 App 式布局，保留搜索、分类、片库和详情。无边框时拖动顶部细条移动窗口。").font(.caption).foregroundStyle(.secondary)
            }
            Section("显隐") {
                Text("\(desktop.shortcuts.shortcut(.visibility)?.display ?? "未设置") · \(desktop.shortcuts.globalStatus)")
                Text("显隐热键在其他应用中也有效；隐藏不会停止当前播放。隐藏后也可点击 Dock 图标找回窗口。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var manager: ShortcutManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("点击组合键后直接按下新快捷键，立即生效。Esc 取消，Delete 清除。").font(.caption).foregroundStyle(.secondary)
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(MovieAction.allCases) { action in
                        HStack {
                            Text(action.title)
                            if action == .visibility { Text("全局").font(.caption2).foregroundStyle(Theme.accent) }
                            Spacer()
                            Button(manager.recording == action ? "按下组合键…" : manager.shortcut(action)?.display ?? "未设置") { manager.beginRecording(action) }
                                .frame(width: 180).accessibilityLabel("设置\(action.title)快捷键")
                            Button { _ = manager.set(nil, for: action) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("清除\(action.title)快捷键")
                        }.padding(.vertical, 9)
                        Divider()
                    }
                }
            }
            HStack {
                Text(manager.globalStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认快捷键") { manager.restoreDefaults() }
            }
            Text("除全局显隐外，其余快捷键在本应用内生效。系统标准编辑、退出和关闭窗口快捷键保持 macOS 行为。").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).onDisappear { manager.cancelRecording() }
    }
}

struct WindowDragStrip: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

struct WindowResizeHandle: NSViewRepresentable {
    final class ResizeView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.4).setStroke()
            for inset in [CGFloat(3), 7, 11] {
                let line = NSBezierPath(); line.move(to: NSPoint(x: inset, y: 3)); line.line(to: NSPoint(x: bounds.width - 3, y: bounds.height - inset)); line.stroke()
            }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let origin = NSEvent.mouseLocation, frame = window.frame
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let point = NSEvent.mouseLocation
                let width = max(260, frame.width + point.x - origin.x)
                let height = max(160, frame.height - point.y + origin.y)
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
            }
        }
    }
    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {}
}
