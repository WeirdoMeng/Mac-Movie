import AppKit
import Carbon
import SwiftUI

enum ShortcutChecks {
    @MainActor static func run() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw SourceError.invalid("CHECK FAILED: " + message) }
            count += 1
        }
        let suite = "local.macmovie.shortcut-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        try check(Set(MovieAction.allCases.map { $0.standard.display }).count == MovieAction.allCases.count, "默认快捷键没有重复")
        try check(MovieShortcut(0, [.control, .option]).validation(global: true) == nil, "物理按键 A 的代码 0 合法")
        try check(MovieShortcut(4, []).validation(global: true) != nil, "全局热键不能没有修饰键")
        try check(MovieShortcut(4, .shift).validation(global: true) != nil, "全局热键不能仅使用 Shift")
        try check(MovieShortcut(12, .command).validation(global: false) != nil, "保留系统退出快捷键")
        try check(!manager.set(MovieAction.next.standard, for: .previous), "拒绝本应用内快捷键冲突")
        let changed = MovieShortcut(35, [.control, .option])
        try check(manager.set(changed, for: .playPause), "支持重新绑定播放")
        try check(manager.shortcut(.playPause) == changed && manager.shortcut(.playPause) != MovieAction.playPause.standard, "修改即时替换旧绑定")
        try check(manager.set(nil, for: .next) && manager.shortcut(.next) == nil, "可以清除快捷键")
        let restored = ShortcutManager(defaults: defaults)
        try check(restored.shortcut(.playPause) == changed && restored.shortcut(.next) == nil, "重建后保留新绑定与已停用状态")
        manager.restoreDefaults()
        try check(manager.shortcut(.playPause) == MovieAction.playPause.standard && manager.shortcut(.next) == MovieAction.next.standard, "恢复默认绑定")
        try check(MovieShortcut(123, [.control, .option]).carbonModifiers == UInt32(controlKey | optionKey), "Carbon 修饰键映射")
        try check(DesktopController.opacity(-1) == 0.1 && DesktopController.opacity(2) == 1 && DesktopController.opacity(.nan) == 1, "透明度安全范围")
        // Snapshot of the user's saved bindings, read on 2026-10-20.
        let expected: [(MovieAction, UInt32, NSEvent.ModifierFlags)] = [
            (.visibility, 21, .control), (.windowFill, 3, [.control, .option]),
            (.opacityUp, 24, .control), (.opacityDown, 27, .control),
            (.playPause, 49, []), (.seekBack, 123, []), (.seekForward, 124, [])
        ]
        for (action, key, flags) in expected { try check(action.standard == MovieShortcut(key, flags), "采用用户当前默认：\(action.title)") }
        print("PASS: \(count) shortcut and window preference checks")
    }

    @MainActor static func windowCheck() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw SourceError.invalid("WINDOW CHECK FAILED: " + message) }
            count += 1
        }
        let suite = "local.macmovie.window-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let desktop = DesktopController(defaults: defaults)
        // Use uncommon combinations during the test so running applications retain their defaults.
        let first = MovieShortcut(106, [.command, .option, .control, .shift])
        let second = MovieShortcut(113, [.command, .option, .control, .shift])
        _ = desktop.shortcuts.set(first, for: .visibility)
        let library = Library(defaults: defaults)
        library.page = CatalogPage(movies: (0..<6).map { Movie(id: "layout-\($0)", title: ["嫁金钗", "楚离", "魅影神捕", "九门2026", "百花杀", "雀骨"][$0], poster: nil, remark: "更新至第12集") })
        library.detail = MovieDetail(movie: Movie(id: "window-test", title: "测试影片", poster: nil, remark: ""), summary: "", metadata: "", episodes: [])
        let window = MovieWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MovieRootView(model: library, desktop: desktop).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        defer { desktop.shortcuts.stop(); window.orderOut(nil); defaults.removePersistentDomain(forName: suite) }
        desktop.attach(window, library: library)
        window.orderFront(nil)
        try check(window.resizeIncrements == NSSize(width: 1, height: 1) && window.contentResizeIncrements == NSSize(width: 1, height: 1), "自由缩放使用有效增量，不设置零宽高比")
        try check(desktop.shortcuts.globalStatus.hasPrefix("已生效"), "Carbon 全局热键注册")
        let original = window.frame
        desktop.perform(.windowFill)
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(desktop.windowFill && window.frame.width == original.width && !window.styleMask.contains(.fullScreen), "窗口全屏保持宽度且不进入系统全屏")
        desktop.perform(.windowFill)
        try check(!desktop.windowFill && window.frame == original, "退出窗口全屏恢复之前高度")
        desktop.preferences.borderless = true
        try check(!window.styleMask.contains(.titled) && window.styleMask.contains(.resizable), "无边框保留自由缩放")
        try check(window.canBecomeKey && window.canBecomeMain && window.frame == original, "无边框仍可获得键盘焦点且不改变尺寸")
        desktop.preferences.opacity = 0.35
        try check(abs(window.alphaValue - 0.35) < 0.001, "不透明度即时应用")
        desktop.preferences.pinned = true
        try check(window.level == .floating, "置顶即时应用")
        desktop.preferences.borderless = false
        try check(window.styleMask.contains(.titled) && window.frame == original, "恢复边框与原尺寸")
        window.setFrame(NSRect(x: 100, y: 100, width: 320, height: 210), display: false)
        desktop.saveFrame()
        try check(window.frame.width == 320 && window.frame.height == 210, "可调整为小窗口且不锁定比例")
        let reload = DesktopController(defaults: defaults)
        try check(abs(reload.preferences.opacity - 0.35) < 0.001 && reload.preferences.pinned && reload.preferences.frame != nil, "窗口偏好持久化")
        var occupied: EventHotKeyRef?
        let status = RegisterEventHotKey(second.keyCode, second.carbonModifiers, EventHotKeyID(signature: 0x74657374, id: 1), GetApplicationEventTarget(), 0, &occupied)
        try check(status == noErr, "准备热键冲突样本")
        defer { if let occupied { UnregisterEventHotKey(occupied) } }
        try check(!desktop.shortcuts.set(second, for: .visibility) && desktop.shortcuts.shortcut(.visibility) == first, "全局注册冲突时保留原绑定")
        if let occupied { UnregisterEventHotKey(occupied) }; occupied = nil
        try check(desktop.shortcuts.set(second, for: .visibility) && desktop.shortcuts.globalStatus.hasPrefix("已生效"), "全局热键即时重注册")
        var released: EventHotKeyRef?
        let releaseStatus = RegisterEventHotKey(first.keyCode, first.carbonModifiers, EventHotKeyID(signature: 0x74657374, id: 2), GetApplicationEventTarget(), 0, &released)
        if let released { UnregisterEventHotKey(released) }
        try check(releaseStatus == noErr, "修改后旧全局热键已释放")
        let menuDelegate = MovieAppDelegate(defaults: defaults)
        menuDelegate.prepareMenus()
        try check(NSApp.mainMenu?.items.map(\.title) == ["摸鱼视界", "播放", "窗口"], "顶部仅保留三个中文菜单")
        let items = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }
        try check(items.allSatisfy { $0.title.range(of: "\\p{Han}", options: .regularExpression) != nil }, "所有菜单项均为中文")
        let custom = MovieShortcut(35, [.control, .option])
        _ = menuDelegate.desktop.shortcuts.set(custom, for: .playPause)
        let updated = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }.first { ($0.representedObject as? String) == MovieAction.playPause.rawValue }
        try check(updated?.keyEquivalent == "p" && updated?.keyEquivalentModifierMask == [.control, .option], "菜单快捷键即时刷新")

        library.showDetail = false; desktop.windowFill = false
        window.setContentSize(NSSize(width: 1100, height: 740))
        desktop.saveFrame()
        window.setContentSize(NSSize(width: 400, height: 700))
        desktop.attach(window, library: library, restoreWindowSize: false)
        try check(abs(window.contentLayoutRect.width - 400) < 1 && abs(window.contentLayoutRect.height - 700) < 1, "启动小窗口不被上次大窗口尺寸覆盖")
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        try check(!desktop.windowFill && abs(host.bounds.width - 400) < 1, "小窗口保留 App 浏览布局，不自动窗口全屏")
        func categoryScroll(in view: NSView) -> MouseWheelScrollView? {
            if let scroll = view as? MouseWheelScrollView { return scroll }
            return view.subviews.compactMap { categoryScroll(in: $0) }.first
        }
        let categories = categoryScroll(in: host)
        try check(categories != nil && (categories?.documentView?.frame.width ?? 0) > 400, "分类栏内容宽度可横向滚动")
        if let categories,
           let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cgEvent) {
            categories.scrollWheel(with: wheel)
            try check(categories.contentView.bounds.minX > 0, "普通鼠标纵向滚轮转换为分类栏横向滚动")
        } else { try check(false, "创建鼠标滚轮样本") }
        desktop.preferences.borderless = true
        window.setFrame(NSRect(origin: window.frame.origin, size: DesktopController.defaultWindowSize), display: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        try check(window.frame.size == NSSize(width: 299, height: 531) && host.bounds.size == window.frame.size, "默认尺寸使用用户当前无边框窗口的 299×531 点")
        let compactFrame = window.frame
        desktop.perform(.windowFill)
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        print("WINDOW fit: before=\(compactFrame), after=\(window.frame), content=\(host.bounds)")
        try check(window.frame.width == compactFrame.width && window.frame.height == ceil(compactFrame.width * 9 / 16),
                  "小窗口全屏只按视频比例调整高度，工具栏不占额外空间")
        try check(abs(window.frame.maxY - compactFrame.maxY) < 1, "调整高度保持窗口顶部位置")
        let fitted = window.frame
        desktop.fitWindowPlayer(contentHeight: host.bounds.height)
        try check(window.frame == fitted, "相同布局高度不会反复调整窗口")
        desktop.windowFill = false
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        try check(window.frame == compactFrame, "退出小窗口全屏准确恢复原高度和位置")
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scrolls = scrollViews(in: host)
        try check(!scrolls.isEmpty && scrolls.allSatisfy { !$0.hasVerticalScroller && !$0.hasHorizontalScroller }, "实际滚动容器关闭横竖滚动条")
        if let catalog = scrolls.first(where: { !($0 is MouseWheelScrollView) && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height }),
           let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cgEvent) {
            let original = catalog.contentView.bounds.origin
            catalog.scrollWheel(with: wheel)
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(catalog.contentView.bounds.origin != original && !catalog.hasVerticalScroller, "隐藏滚动条后仍能滚动片库")
        } else { try check(false, "片库具有可滚动内容") }
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/compact-home.png")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: destination)
        }
        library.section = BrowseSection.all.first { $0.id == "2" }!
        library.page.filters = (0..<6).map { index in
            FilterGroup(title: "筛选\(index)", options: [PageLink(title: "全部", url: URL(string: "https://example.com/filter/\(index)")!, selected: true)])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        let horizontalRows = scrollViews(in: host).compactMap { $0 as? MouseWheelScrollView }
        try check(horizontalRows.count == 2, "分类与筛选栏均使用鼠标滚轮横向滚动")
        if let filters = horizontalRows.last,
           let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0).flatMap({ NSEvent(cgEvent: $0) }) {
            filters.scrollWheel(with: event)
            try check(filters.contentView.bounds.minX > 0, "筛选栏普通鼠标滚轮实际移动内容")
        } else { try check(false, "准备筛选栏鼠标事件") }
        let settingsHost = NSHostingView(rootView: SettingsView(model: library).preferredColorScheme(.dark))
        settingsHost.sizingOptions = []
        window.contentView = settingsHost
        window.setContentSize(NSSize(width: 460, height: 430))
        try await Task.sleep(nanoseconds: 250_000_000)
        settingsHost.layoutSubtreeIfNeeded()
        let settingsScrolls = scrollViews(in: settingsHost)
        try check(!settingsScrolls.isEmpty && settingsScrolls.allSatisfy { !$0.hasVerticalScroller && !$0.hasHorizontalScroller }, "设置 Form 保持滚动且隐藏原生滚动条")
        library.showDetail = false
        library.section = BrowseSection.all[0]
        library.page.filters = []
        window.contentView = host
        window.setFrame(NSRect(origin: window.frame.origin, size: DesktopController.defaultWindowSize), display: false)
        window.makeKeyAndOrderFront(nil)
        desktop.focusSearch = UUID()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(window.firstResponder is NSTextView, "搜索命令可以将焦点放入输入框")
        library.select(library.detail!.movie, resume: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(!(window.firstResponder is NSTextView), "选片后移出输入焦点，恢复播放器快捷键")
        print("PASS: \(count) real AppKit window and Carbon registration checks")
        try await InteractionChecks.run()
    }
}
