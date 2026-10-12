import AppKit
import Carbon

/// A global shortcut: a virtual key code plus Carbon modifier flags, with the key's display name.
struct HotKey: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let preferenceKey = "app.hotKey"

    /// Apple's menu order: ⌃ ⌥ ⇧ ⌘.
    private static let modifierOrder: [(flag: Int, symbol: String, name: String, menu: NSEvent.ModifierFlags)] = [
        (controlKey, "⌃", "Control", .control),
        (optionKey, "⌥", "Option", .option),
        (shiftKey, "⇧", "Shift", .shift),
        (cmdKey, "⌘", "Command", .command)
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]

    /// Reads a shortcut from a key press. Returns nil for modifier-only presses.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let code = Int(event.keyCode)
        guard let name = Self.namedKeys[code] ?? event.characters(byApplyingModifiers: [])?.uppercased(),
              !name.isEmpty, !name.contains(where: \.isNewline) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        keyCode = UInt32(code)
        modifiers = Self.modifierOrder.reduce(0) { flags.contains($1.menu) ? $0 | UInt32($1.flag) : $0 }
        key = name
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private var activeModifiers: [(flag: Int, symbol: String, name: String, menu: NSEvent.ModifierFlags)] {
        Self.modifierOrder.filter { modifiers & UInt32($0.flag) != 0 }
    }

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("F") && Int(key.dropFirst()) != nil }

    /// A global shortcut needs ⌃, ⌥, or ⌘ (Shift alone would swallow typing); function keys may stand alone.
    var isValidGlobalShortcut: Bool {
        isFunctionKey || modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    var keys: [String] { activeModifiers.map(\.symbol) + [key] }

    var symbol: String { keys.joined() }

    var description: String { (activeModifiers.map(\.name) + [key]).joined(separator: " + ") }

    var menuModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(activeModifiers.map(\.menu)) }

    /// Menus can show single printable keys only; others go without a key equivalent.
    var menuKeyEquivalent: String { key.count == 1 && Self.namedKeys[Int(keyCode)] == nil ? key.lowercased() : "" }

    static func saved(in defaults: UserDefaults = .standard, default fallback: HotKey) -> HotKey {
        saved(in: defaults, key: preferenceKey, default: fallback)
    }

    static func saved(in defaults: UserDefaults = .standard, key preference: String, default fallback: HotKey) -> HotKey {
        guard let stored = defaults.dictionary(forKey: preference),
              let code = stored["keyCode"] as? Int, let flags = stored["modifiers"] as? Int, let key = stored["key"] as? String,
              case let hotKey = HotKey(keyCode: UInt32(code), modifiers: UInt32(flags), key: key), hotKey.isValidGlobalShortcut
        else { return fallback }
        return hotKey
    }

    func save(in defaults: UserDefaults = .standard) {
        save(in: defaults, key: Self.preferenceKey)
    }

    func save(in defaults: UserDefaults = .standard, key preference: String) {
        defaults.set(["keyCode": Int(keyCode), "modifiers": Int(modifiers), "key": key], forKey: preference)
    }
}

/// The global shortcuts Snapok registers. Each has its own Carbon id and preference.
enum HotKeyAction: UInt32, CaseIterable, Sendable {
    /// Starts a new screenshot.
    case capture = 1
    /// Pins the most recent finished screenshot (or the clipboard image) to the screen.
    case pin = 2

    var preferenceKey: String {
        switch self {
        case .capture: return HotKey.preferenceKey
        case .pin: return "app.pinHotKey"
        }
    }

    @MainActor var defaultHotKey: HotKey {
        switch self {
        case .capture: return AppChannel.defaultHotKey
        case .pin: return AppChannel.defaultPinHotKey
        }
    }
}

/// Owns the Carbon registration of the global shortcuts so they can be changed while the app runs.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    static let didChange = Notification.Name("HotKeyCenter.didChange")
    private static let signature = OSType(0x534E4150)

    private var hotKeys: [HotKeyAction: HotKey] = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map {
        ($0, HotKey.saved(key: $0.preferenceKey, default: $0.defaultHotKey))
    })
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlers: [HotKeyAction: () -> Void] = [:]

    /// The screenshot shortcut.
    var current: HotKey { hotKey(for: .capture) }
    /// The pin-to-screen shortcut.
    var pinHotKey: HotKey { hotKey(for: .pin) }

    var onPress: (() -> Void)? {
        get { handlers[.capture] }
        set { handlers[.capture] = newValue }
    }

    var onPinPress: (() -> Void)? {
        get { handlers[.pin] }
        set { handlers[.pin] = newValue }
    }

    func hotKey(for action: HotKeyAction) -> HotKey {
        hotKeys[action] ?? action.defaultHotKey
    }

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == HotKeyCenter.signature, let action = HotKeyAction(rawValue: hotKeyID.id) else { return noErr }
            log("hotkey pressed: \(action)")
            Task { @MainActor in HotKeyCenter.shared.handlers[action]?() }
            return noErr
        }, 1, &eventType, nil, nil)
        HotKeyAction.allCases.forEach { register($0) }
    }

    /// Switches the screenshot shortcut; keeps the old one and returns false when macOS refuses it.
    func change(to hotKey: HotKey) -> Bool { change(.capture, to: hotKey) == .changed }

    enum ChangeResult { case changed, conflict, refused }

    /// Switches one shortcut. Two actions may not share a key; macOS may refuse keys owned by other apps.
    func change(_ action: HotKeyAction, to hotKey: HotKey) -> ChangeResult {
        if HotKeyAction.allCases.contains(where: { $0 != action && self.hotKey(for: $0) == hotKey }) { return .conflict }
        let previous = self.hotKey(for: action)
        hotKeys[action] = hotKey
        guard register(action) else {
            hotKeys[action] = previous
            register(action)
            return .refused
        }
        hotKey.save(key: action.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return .changed
    }

    /// Releases the shortcuts while the user records a new one, so pressing one does not trigger it.
    func suspend() { HotKeyAction.allCases.forEach { unregister($0) } }

    func resume() {
        for action in HotKeyAction.allCases where refs[action] == nil { register(action) }
    }

    func stop() { suspend() }

    @discardableResult
    private func register(_ action: HotKeyAction) -> Bool {
        unregister(action)
        let hotKey = self.hotKey(for: action)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        log(status == noErr ? "hotkey registered (\(action)): \(hotKey.description)" : "failed to register hotkey (\(action)) \(hotKey.description), status=\(status)")
        if status == noErr, let ref { refs[action] = ref }
        return status == noErr
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = refs[action] { UnregisterEventHotKey(ref) }
        refs[action] = nil
    }
}
