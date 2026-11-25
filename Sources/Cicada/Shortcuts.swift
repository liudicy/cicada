import AppKit
import Carbon.HIToolbox

// MARK: - Shortcut

/// A key plus Carbon modifiers, or the right ⌥ key on its own (push to talk).
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: Int

    static let rightOption = Shortcut(keyCode: kVK_RightOption, modifiers: 0)
    static let defaultTalk = rightOption
    static let defaultToggle = Shortcut(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey)

    var isRightOption: Bool { self == .rightOption }

    var stored: String { "\(keyCode):\(modifiers)" }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(stored: String?) {
        let p = (stored ?? "").split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        self.init(keyCode: p[0], modifiers: p[1])
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        self.init(keyCode: Int(keyCode), modifiers: m)
    }

    /// Key caps in display order, e.g. ["⌃", "⌥", "S"].
    var keys: [String] {
        if isRightOption { return [L("右 ⌥")] }
        var k: [String] = []
        if modifiers & controlKey != 0 { k.append("⌃") }
        if modifiers & optionKey != 0 { k.append("⌥") }
        if modifiers & shiftKey != 0 { k.append("⇧") }
        if modifiers & cmdKey != 0 { k.append("⌘") }
        k.append(Shortcut.keyName(keyCode))
        return k
    }

    var display: String { keys.joined(separator: " ") }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_RightOption: L("右 ⌥"),
    ]

    /// Names worked out on the main thread. SwiftUI sometimes builds the panel off it, and the
    /// input-source calls assert the main queue there (a crash since 1.4.0): off it, the last name.
    private static let nameLock = NSLock()
    nonisolated(unsafe) private static var names: [Int: String] = [:]

    /// The character the key types on the current layout (US letters on non-Latin layouts).
    static func keyName(_ code: Int) -> String {
        if let f = functionKeys[code] { return f }
        if let n = named[code] { return n }
        guard Thread.isMainThread else {
            nameLock.lock(); defer { nameLock.unlock() }
            return names[code] ?? "#\(code)"
        }
        let name = layoutName(code)
        nameLock.lock(); names[code] = name; nameLock.unlock()
        return name
    }

    private static func layoutName(_ code: Int) -> String {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Why this can't be a global shortcut, or nil. ⌥ or ⇧ alone types characters in
    /// every app (⌥ Space is a non-breaking space). Bare F keys are brightness/volume on
    /// most Mac keyboards. So a combination needs ⌃ or ⌘.
    var typingProblem: String? {
        if isRightOption { return nil }
        if modifiers & (controlKey | cmdKey) == 0 { return L("请包含 ⌃ 或 ⌘，否则会影响正常打字") }
        return nil
    }

    /// The system already uses it (Spotlight, input sources, Mission Control, screenshots …).
    var isSystemShortcut: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        let mask = controlKey | optionKey | shiftKey | cmdKey
        return list.contains { hk in
            guard (hk["kHISymbolicHotKeyEnabled"] as? Bool) ?? false,
                  let code = (hk["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
                  let mods = (hk["kHISymbolicHotKeyModifiers"] as? NSNumber)?.intValue else { return false }
            return code == keyCode && mods & mask == modifiers & mask
        }
    }
}

// MARK: - Key combination (Carbon)

/// A global key combination via Carbon. Needs no permission, reports press and
/// release, and fails with `eventHotKeyExistsErr` if another app holds the same combo.
final class HotKey {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private(set) var shortcut: Shortcut
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32

    init(id: UInt32, shortcut: Shortcut) {
        self.id = id
        self.shortcut = shortcut
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard hkID.id == hk.id else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { hk.onDown?() } else { hk.onUp?() }
            return noErr
        }, 2, &types, me, &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    var isRegistered: Bool { ref != nil }

    /// Registers `shortcut` (replacing any current one). Returns false if another app holds it.
    @discardableResult
    func register(_ shortcut: Shortcut? = nil) -> Bool {
        unregister()
        if let shortcut { self.shortcut = shortcut }
        let hkID = EventHotKeyID(signature: OSType(0x4C535542), id: id) // 'LSUB'
        let status = RegisterEventHotKey(UInt32(self.shortcut.keyCode), UInt32(self.shortcut.modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            debugLog("hotkey \(self.shortcut.display) not registered: \(status)")
            ref = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

// MARK: - Right ⌥ on its own

/// Hold the right ⌥ key to talk. A modifier on its own can't be a Carbon hotkey, so this
/// listens to key events with a listen-only event tap, which needs "输入监控" (Input
/// Monitoring). Pressing any other key while holding it is a chord (⌥ + letter types
/// accented characters), so the press is cancelled instead of sent.
final class RightOptionKey {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = false

    // Device-dependent modifier bits (IOLLEvent.h).
    private static let rightAlt: UInt64 = 0x40
    private static let otherModifiers: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x2000 // ctrl, shift, cmd, left alt, right ctrl

    static var allowed: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; afterwards only System Settings can grant it.
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard RightOptionKey.allowed else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, user in
            if let user { Unmanaged<RightOptionKey>.fromOpaque(user).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            debugLog("right option: event tap not created")
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        debugLog("right option: listening")
        return true
    }

    func stop() {
        if active { active = false; onCancel?() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags.rawValue
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRight = code == Int64(kVK_RightOption)
            // "I held ⌥ and nothing happened" was the left one (or a keyboard or remote session
            // that only sends it): say so in the log.
            if code == Int64(kVK_Option), flags & 0x20 != 0 { debugLog("right option: left ⌥ pressed, not the talk key") }
            if isRight, flags & RightOptionKey.rightAlt != 0 {
                // Only a clean press starts talking, not ⌘ + right ⌥ and the like.
                if !active, flags & RightOptionKey.otherModifiers == 0 { active = true; onDown?() }
            } else if isRight {
                if active { active = false; onUp?() }
            } else if active {
                active = false
                onCancel?()
            }
        case .keyDown:
            if active { active = false; onCancel?() }
        default:
            break
        }
    }
}
