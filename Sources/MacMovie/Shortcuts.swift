import AppKit
import Carbon
import SwiftUI

enum MovieAction: String, CaseIterable, Identifiable, Codable {
    case visibility, windowFill, borderless, pin, opacityUp, opacityDown, grow, shrink
    case playPause, seekBack, seekForward, previous, next, mute, stop, search, settings, systemFullScreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .visibility: return "全局显隐"
        case .windowFill: return "窗口全屏"
        case .borderless: return "切换无边框"
        case .pin: return "切换窗口置顶"
        case .opacityUp: return "提高不透明度（更实）"
        case .opacityDown: return "降低不透明度（更透）"
        case .grow: return "放大窗口"
        case .shrink: return "缩小窗口"
        case .playPause: return "播放 / 暂停"
        case .seekBack: return "后退 10 秒"
        case .seekForward: return "前进 10 秒"
        case .previous: return "上一集"
        case .next: return "下一集"
        case .mute: return "切换静音"
        case .stop: return "停止播放"
        case .search: return "搜索影片"
        case .settings: return "打开设置"
        case .systemFullScreen: return "系统全屏"
        }
    }
    var standard: MovieShortcut {
        let command = NSEvent.ModifierFlags.command
        switch self {
        case .visibility: return .init(21, .control)
        case .windowFill: return .init(3, [.control, .option])
        case .borderless: return .init(11, [.command, .shift])
        case .pin: return .init(17, command)
        case .opacityUp: return .init(24, .control)
        case .opacityDown: return .init(27, .control)
        case .grow: return .init(24, command)
        case .shrink: return .init(27, command)
        case .playPause: return .init(49, [])
        case .seekBack: return .init(123, [])
        case .seekForward: return .init(124, [])
        case .previous: return .init(123, command)
        case .next: return .init(124, command)
        case .mute: return .init(46, [.command, .shift])
        case .stop: return .init(1, [.command, .shift])
        case .search: return .init(3, command)
        case .settings: return .init(43, command)
        case .systemFullScreen: return .init(3, [.control, .command])
        }
    }
}

struct MovieShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt
    init(_ keyCode: UInt32, _ flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifiers = flags.intersection([.command, .shift, .option, .control]).rawValue
    }
    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var display: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
        (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + Self.keyName(keyCode)
    }
    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"空格",50:"`",53:"Esc",65:"小数点",67:"*",69:"+",75:"/",76:"⌤",78:"−",81:"=",82:"0",83:"1",84:"2",85:"3",86:"4",87:"5",88:"6",89:"7",91:"8",92:"9",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"Help",115:"Home",116:"Page Up",118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return names[code] ?? [64: "F17", 79: "F18", 80: "F19", 90: "F20"][code] ?? "Key \(code)"
    }
    func validation(global: Bool) -> String? {
        if keyCode > 126 || [51, 53, 55, 56, 57, 58, 59, 60, 61, 62, 63, 117].contains(keyCode) { return "请选择普通按键或功能键；Esc 用于取消，Delete 用于清除。" }
        if global && flags.intersection([.command, .option, .control]).isEmpty { return "全局热键至少包含 Command、Option 或 Control。" }
        if !global && flags.isEmpty && ![49, 123, 124, 125, 126, 96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122].contains(keyCode) { return "普通字符请搭配修饰键，避免影响输入。" }
        if flags == .command && [0, 6, 7, 8, 9, 12, 13, 46].contains(keyCode) { return "该组合用于系统编辑、退出或关闭窗口，请选择其他组合。" }
        if flags == [.control, .command] && keyCode == 12 { return "该组合用于系统锁屏，请选择其他组合。" }
        return nil
    }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
    var menuKey: String {
        switch keyCode {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 76: return "\u{3}"
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 27, 78: return "-"
        default:
            let name = Self.keyName(keyCode)
            if name.hasPrefix("F"), let number = Int(name.dropFirst()) { return String(UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(number - 1))!) }
            return name.count == 1 ? name.lowercased() : ""
        }
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    @Published private(set) var bindings: [String: MovieShortcut]
    @Published private(set) var recording: MovieAction?
    @Published var error: String?
    @Published private(set) var globalStatus = "尚未注册"
    var perform: ((MovieAction) -> Void)?
    var bindingsDidChange: (() -> Void)?
    private let defaults: UserDefaults
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var recordingWindow: NSWindow?
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var hotKeyID: UInt32 = 0
    private var started = false
    private var ignoreGlobalUntil = Date.distantPast
    static let key = "macmovie.shortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let standard = Dictionary(uniqueKeysWithValues: MovieAction.allCases.map { ($0.rawValue, $0.standard) })
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: MovieShortcut].self, from: data) { bindings = saved }
        else { bindings = standard }
    }
    func shortcut(_ action: MovieAction) -> MovieShortcut? { bindings[action.rawValue] }

    func start() {
        guard !started else { return }; started = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if id.signature == 0x6D6F7669 && id.id == manager.hotKeyID && manager.recording == nil && Date() > manager.ignoreGlobalUntil { manager.perform?(.visibility) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status == noErr {
            if let shortcut = shortcut(.visibility) { _ = register(shortcut) }
            else { globalStatus = "已停用" }
        } else { globalStatus = "全局热键监听失败（\(status)）" }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated {
                if let self { consumed = self.handle(event) == nil }
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let self, let window = note.object as? NSWindow, self.recordingWindow === window { self.cancelRecording() }
            }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let action = recording {
            guard event.type == .keyDown else { return nil }
            if event.keyCode == 53 { cancelRecording(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { set(nil, for: action); cancelRecording(); return nil }
            if event.isARepeat { return nil }
            let candidate = MovieShortcut(UInt32(event.keyCode), event.modifierFlags)
            if set(candidate, for: action) { cancelRecording() }
            return nil
        }
        guard event.type == .keyDown else { return event }
        let shortcut = MovieShortcut(UInt32(event.keyCode), event.modifierFlags)
        if shortcut.keyCode == 53 && shortcut.flags.isEmpty && performEscape?() == true { return nil }
        do {
            let standard: [UInt32: String] = [0: "selectAll:", 6: "undo:", 7: "cut:", 8: "copy:", 9: "paste:"]
            if shortcut.flags == .command, let name = standard[shortcut.keyCode] {
                return NSApp.sendAction(Selector(name), to: nil, from: nil) ? nil : event
            }
            if shortcut.flags == [.command, .shift] && shortcut.keyCode == 6 {
                return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) ? nil : event
            }
        }
        guard let action = MovieAction.allCases.first(where: { $0 != .visibility && self.shortcut($0) == shortcut }) else { return event }
        if shortcut.flags.isEmpty, NSApp.keyWindow?.firstResponder is NSTextView { return event }
        if !event.isARepeat || [.seekBack, .seekForward, .opacityUp, .opacityDown, .grow, .shrink].contains(action) { perform?(action) }
        return nil
    }
    var performEscape: (() -> Bool)?

    @discardableResult func set(_ shortcut: MovieShortcut?, for action: MovieAction) -> Bool {
        error = nil
        if let shortcut {
            if let message = shortcut.validation(global: action == .visibility) { error = message; return false }
            if let conflict = MovieAction.allCases.first(where: { $0 != action && self.shortcut($0) == shortcut }) {
                error = "该组合已用于“\(conflict.title)”，请先清除或修改原绑定。"; return false
            }
            if action == .visibility, started, recording == nil, shortcut != self.shortcut(.visibility), !register(shortcut) { return false }
            if action == .visibility, started, recording != nil, !register(shortcut) { return false }
        } else if action == .visibility {
            if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil; globalStatus = "已停用"
        }
        bindings[action.rawValue] = shortcut
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.key) }
        bindingsDidChange?()
        return true
    }

    private func register(_ shortcut: MovieShortcut) -> Bool {
        guard handler != nil else { error = "全局热键监听尚未就绪，原绑定已保留。"; return false }
        var candidate: EventHotKeyRef?
        let nextID = hotKeyID &+ 1
        let id = EventHotKeyID(signature: 0x6D6F7669, id: nextID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else {
            error = "全局热键可能已被其他应用占用（\(status)），原绑定已保留。"
            globalStatus = hotKey == nil ? "未注册，请更换组合键" : "原热键仍有效"
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; hotKeyID = nextID; globalStatus = "已生效：\(shortcut.display)"
        ignoreGlobalUntil = Date().addingTimeInterval(0.35)
        return true
    }

    func beginRecording(_ action: MovieAction) {
        cancelRecording()
        recordingWindow = NSApp.keyWindow; recording = action; error = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        globalStatus = "录制期间暂停"
    }
    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil; recordingWindow = nil
        if started, hotKey == nil, let shortcut = shortcut(.visibility) { _ = register(shortcut) }
        else if shortcut(.visibility) == nil { globalStatus = "已停用" }
    }
    func restoreDefaults() {
        cancelRecording()
        if started, shortcut(.visibility) != MovieAction.visibility.standard, !register(MovieAction.visibility.standard) { return }
        bindings = Dictionary(uniqueKeysWithValues: MovieAction.allCases.map { ($0.rawValue, $0.standard) })
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.key) }
        bindingsDidChange?()
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        started = false
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
