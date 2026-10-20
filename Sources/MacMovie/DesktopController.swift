import AppKit
import SwiftUI

struct WindowPreferences: Codable, Equatable {
    var borderless = false
    var pinned = false
    var opacity: Double = 1
    var frame: String?
}

final class MovieWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class DesktopController: ObservableObject {
    @Published var preferences: WindowPreferences {
        didSet {
            guard preferences != oldValue else { return }
            persist(); applyAppearance()
        }
    }
    @Published var windowFill = false
    @Published var showSettings = false
    @Published var focusSearch = UUID()
    let shortcuts: ShortcutManager
    weak var window: MovieWindow?
    private let defaults: UserDefaults
    private weak var library: Library?
    private var applying = false
    private var savedStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    static let key = "macmovie.window.v1"
    static let defaultWindowSize = NSSize(width: 299, height: 531)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), var saved = try? JSONDecoder().decode(WindowPreferences.self, from: data) {
            saved.opacity = Self.opacity(saved.opacity); preferences = saved
        } else { preferences = WindowPreferences() }
        shortcuts = ShortcutManager(defaults: defaults)
        shortcuts.perform = { [weak self] action in self?.perform(action) }
        shortcuts.performEscape = { [weak self] in
            guard let self, self.windowFill, !self.showSettings else { return false }
            self.windowFill = false
            return true
        }
    }
    static func opacity(_ value: Double) -> Double { value.isFinite ? min(1, max(0.1, value)) : 1 }

    func attach(_ window: MovieWindow, library: Library, restoreWindowSize: Bool = true) {
        self.window = window; self.library = library; savedStyle = window.styleMask
        window.contentMinSize = NSSize(width: 260, height: 160)
        window.minSize = NSSize(width: 260, height: 160)
        // Cancel ratio constraints through resize increments. Setting a 0×0
        // ratio explicitly can produce invalid geometry during native live resize.
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        if let frame = preferences.frame {
            var rect = NSRectFromString(frame)
            if rect.width >= 260, rect.height >= 160, rect.width.isFinite, rect.height.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite {
                if !restoreWindowSize { rect.size = window.frame.size }
                window.setFrame(rect, display: false)
                keepOnScreen()
            }
        }
        applyAppearance(); shortcuts.start()
    }

    func applyAppearance() {
        guard let window, !applying else { return }
        applying = true
        defer { applying = false }
        if !window.styleMask.contains(.fullScreen) {
            let style: NSWindow.StyleMask = preferences.borderless ? [.borderless, .resizable, .miniaturizable] : savedStyle
            if window.styleMask != style {
                let frame = window.frame
                window.styleMask = style
                window.setFrame(frame, display: true)
            }
            window.titleVisibility = preferences.borderless ? .hidden : .visible
            window.titlebarAppearsTransparent = preferences.borderless
            window.hasShadow = !preferences.borderless
            window.isOpaque = !preferences.borderless
            window.backgroundColor = preferences.borderless ? .clear : .windowBackgroundColor
            window.isMovableByWindowBackground = preferences.borderless
        }
        window.alphaValue = Self.opacity(preferences.opacity)
        window.level = preferences.pinned ? .floating : .normal
    }

    func saveFrame() {
        guard let window, !applying, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        preferences.frame = NSStringFromRect(window.frame)
    }

    private func keepOnScreen() {
        guard let window else { return }
        let screens = NSScreen.screens
        let screen = screens.max { a, b in
            let x = a.visibleFrame.intersection(window.frame), y = b.visibleFrame.intersection(window.frame)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        } ?? NSScreen.main
        guard let screen else { return }
        var frame = window.frame
        frame.size.width = min(max(260, frame.width), screen.visibleFrame.width)
        frame.size.height = min(max(160, frame.height), screen.visibleFrame.height)
        frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - frame.width))
        frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    func showWindow() {
        guard let window else { return }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func toggleVisibility() {
        shortcuts.cancelRecording()
        if NSApp.isHidden || window?.isVisible != true || window?.isMiniaturized == true { showWindow() }
        else { library?.pauseForHiding(); NSApp.hide(nil) }
    }
    func openLibrary() {
        browse()
        guard let window else { return }
        var frame = window.frame
        frame.size = NSSize(width: max(frame.width, 1000), height: max(frame.height, 680))
        window.setFrame(frame, display: true); keepOnScreen(); showWindow()
    }
    func browse() { windowFill = false; library?.showDetail = false; showWindow() }
    func resize(_ multiplier: Double) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let size = NSSize(width: max(260, window.frame.width * multiplier), height: max(160, window.frame.height * multiplier))
        window.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
        keepOnScreen(); saveFrame()
    }
    func perform(_ action: MovieAction) {
        switch action {
        case .visibility: toggleVisibility()
        case .windowFill:
            guard library?.detail != nil else { return }
            windowFill.toggle()
        case .borderless: preferences.borderless.toggle()
        case .pin: preferences.pinned.toggle()
        case .opacityUp: preferences.opacity = Self.opacity(preferences.opacity + 0.05)
        case .opacityDown: preferences.opacity = Self.opacity(preferences.opacity - 0.05)
        case .grow: resize(1.12)
        case .shrink: resize(1 / 1.12)
        case .playPause: library?.togglePlayback()
        case .seekBack: library?.seek(to: (library?.position ?? 0) - 10)
        case .seekForward: library?.seek(to: (library?.position ?? 0) + 10)
        case .previous: if let previous = library?.previousEpisode { library?.play(previous) }
        case .next: if let next = library?.nextEpisode { library?.play(next, from: 0) }
        case .mute: library?.settings.muted.toggle(); library?.updateSettings()
        case .stop: library?.stop()
        case .search: browse(); focusSearch = UUID()
        case .settings: showWindow(); showSettings = true
        case .systemFullScreen: window?.toggleFullScreen(nil)
        }
    }
    private func persist() {
        if let bytes = try? JSONEncoder().encode(preferences) { defaults.set(bytes, forKey: Self.key) }
    }
}

@MainActor
final class MovieAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let library: Library
    let desktop: DesktopController
    private var mainWindow: MovieWindow?

    init(defaults: UserDefaults = .standard) {
        library = Library(defaults: defaults)
        desktop = DesktopController(defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains(where: { ["--check", "--probe", "--audit", "--window-check"].contains($0) }) else { return }
        prepareMenus()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1180, height: 800)
        let size = NSSize(width: min(DesktopController.defaultWindowSize.width, screen.width), height: min(DesktopController.defaultWindowSize.height, screen.height))
        let window = MovieWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // Default is the whole window size, including any title bar.
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.title = "摸鱼视界"; window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSHostingView(rootView: MovieRootView(model: library, desktop: desktop).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        mainWindow = window
        desktop.attach(window, library: library, restoreWindowSize: false)
        desktop.showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { desktop.showWindow(); return true }
    func windowDidResize(_ notification: Notification) { desktop.saveFrame() }
    func windowDidMove(_ notification: Notification) { desktop.saveFrame() }
    func windowDidExitFullScreen(_ notification: Notification) { desktop.applyAppearance() }
    func windowWillClose(_ notification: Notification) { library.saveProgress(); library.player.pause() }
    func applicationWillTerminate(_ notification: Notification) { library.saveProgress(); desktop.shortcuts.stop() }

    func prepareMenus() {
        desktop.shortcuts.bindingsDidChange = { [weak self] in self?.installMenu() }
        installMenu()
    }
    private func installMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        func item(_ title: String, selector: Selector, key: String = "", in menu: NSMenu) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        func action(_ action: MovieAction, in menu: NSMenu) {
            let item = NSMenuItem(title: action.title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue
            if action != .visibility, let shortcut = desktop.shortcuts.shortcut(action) { item.keyEquivalent = shortcut.menuKey; item.keyEquivalentModifierMask = shortcut.flags }
            menu.addItem(item)
        }
        let app = submenu("摸鱼视界")
        item("显示主窗口", selector: #selector(showMain), in: app)
        action(.settings, in: app)
        action(.visibility, in: app)
        app.addItem(.separator())
        item("退出摸鱼视界", selector: #selector(quit), key: "q", in: app)
        let playback = submenu("播放")
        for command in [MovieAction.playPause, .seekBack, .seekForward, .previous, .next, .mute, .stop] { action(command, in: playback) }
        let window = submenu("窗口")
        for command in [MovieAction.windowFill, .systemFullScreen, .borderless, .pin] { action(command, in: window) }
        window.addItem(.separator())
        action(.opacityUp, in: window); action(.opacityDown, in: window)
        item("恢复不透明", selector: #selector(restoreOpacity), in: window)
        window.addItem(.separator())
        action(.grow, in: window); action(.shrink, in: window)
        item("恢复窗口尺寸", selector: #selector(restoreSize), in: window)
        window.addItem(.separator())
        item("最小化窗口", selector: #selector(minimize), key: "m", in: window)
        item("关闭窗口", selector: #selector(closeMain), key: "w", in: window)
        // Rebuild the accelerators as Reader-Mac does, so removed keys stop working immediately.
        NSApp.mainMenu = nil; NSApp.mainMenu = main
        NSApp.helpMenu = nil; NSApp.windowsMenu = nil; NSApp.servicesMenu = nil
    }
    @objc private func runMenuAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let action = MovieAction(rawValue: raw) { desktop.perform(action) }
    }
    @objc private func showMain() { desktop.showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func minimize() { desktop.window?.miniaturize(nil) }
    @objc private func closeMain() { desktop.window?.performClose(nil) }
    @objc private func restoreSize() { desktop.openLibrary() }
    @objc private func restoreOpacity() { desktop.preferences.opacity = 1 }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let action = MovieAction(rawValue: raw) else { return true }
        switch action {
        case .playPause: item.title = library.isPlaying ? "暂停" : "播放"; return library.episode != nil
        case .seekBack, .seekForward, .mute, .stop: return library.episode != nil
        case .previous: return library.previousEpisode != nil
        case .next: return library.nextEpisode != nil
        case .windowFill: item.state = desktop.windowFill ? .on : .off; return library.detail != nil
        case .borderless: item.state = desktop.preferences.borderless ? .on : .off
        case .pin: item.state = desktop.preferences.pinned ? .on : .off
        default: break
        }
        return true
    }
}
