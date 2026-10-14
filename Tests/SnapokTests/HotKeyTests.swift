import AppKit
import Carbon
extension Bundle { static var module: Bundle { .main } }

@main @MainActor
struct HotKeyTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        func press(_ characters: String, _ code: Int, _ flags: NSEvent.ModifierFlags) -> HotKey? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))
                .flatMap(HotKey.init(event:))
        }

        // Key presses become shortcuts with modifiers in Apple's ⌃⌥⇧⌘ order.
        let captured = press("s", kVK_ANSI_S, [.command, .shift])!
        precondition(captured.keyCode == UInt32(kVK_ANSI_S) && captured.modifiers == UInt32(cmdKey | shiftKey))
        precondition(captured.symbol == "⇧⌘S" && captured.description == "Shift + Command + S", "got \(captured.symbol)")
        precondition(captured.menuKeyEquivalent == "s" && captured.menuModifiers == [.shift, .command])
        precondition(captured.isValidGlobalShortcut)

        // Shift alone would swallow typing; function keys may stand alone.
        precondition(!press("a", kVK_ANSI_A, [.shift])!.isValidGlobalShortcut)
        precondition(!press("a", kVK_ANSI_A, [])!.isValidGlobalShortcut)
        let f5 = press("\u{F708}", kVK_F5, [])!
        precondition(f5.key == "F5" && f5.isValidGlobalShortcut && f5.menuKeyEquivalent.isEmpty)
        precondition(press(" ", kVK_Space, [.control])!.symbol == "⌃Space")

        // Shortcuts persist; missing or invalid stored values fall back to the default.
        let suite = "Snapok.HotKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fallback = AppChannel.defaultHotKey
        precondition(HotKey.saved(in: defaults, default: fallback) == fallback)
        captured.save(in: defaults)
        precondition(HotKey.saved(in: UserDefaults(suiteName: suite)!, default: fallback) == captured)
        defaults.set(["keyCode": kVK_ANSI_A, "modifiers": shiftKey, "key": "A"], forKey: HotKey.preferenceKey)
        precondition(HotKey.saved(in: defaults, default: fallback) == fallback)
        precondition(fallback.symbol == "⌥⇧A", "development builds default to Shift + Option + A")

        // The pin shortcut has its own preference and default, distinct from the capture shortcut.
        let pinFallback = HotKeyAction.pin.defaultHotKey
        precondition(pinFallback != fallback && pinFallback.isValidGlobalShortcut && pinFallback.symbol == "⌥⇧T", "got \(pinFallback.symbol)")
        precondition(HotKey.saved(in: defaults, key: HotKeyAction.pin.preferenceKey, default: pinFallback) == pinFallback)
        f5.save(in: defaults, key: HotKeyAction.pin.preferenceKey)
        precondition(HotKey.saved(in: defaults, key: HotKeyAction.pin.preferenceKey, default: pinFallback) == f5)
        precondition(HotKeyAction.pin.preferenceKey != HotKeyAction.capture.preferenceKey)
        // Paste-styled has its own key and default, and only it waits to be armed.
        precondition(Set(HotKeyAction.allCases.map(\.preferenceKey)).count == HotKeyAction.allCases.count, "Each shortcut saves under its own key")
        let fallbacks = HotKeyAction.allCases.map(\.defaultHotKey)
        precondition(fallbacks.indices.allSatisfy { i in fallbacks.indices.allSatisfy { j in i == j || fallbacks[i] != fallbacks[j] } },
                     "Default shortcuts never collide")
        precondition(HotKeyAction.allCases.filter(\.isArmedOnly) == [.pasteStyled], "Only paste-styled is armed on demand")
        precondition(HotKeyAction.pasteStyled.defaultHotKey.key == "V", "Paste-styled defaults to a V shortcut")

        // Tool keys: one plain key each, never shared, never an editor command.
        let toolSuite = "snapok.toolshortcut.tests.\(UUID().uuidString)"
        let tools = UserDefaults(suiteName: toolSuite)!
        defer { tools.removePersistentDomain(forName: toolSuite) }
        let rect = ToolKind.rect.rawValue
        precondition(ToolShortcuts.hotKey(for: rect, in: tools).key == "R")
        let q = press("q", kVK_ANSI_Q, [])!
        precondition(ToolShortcuts.change(rect, to: q, in: tools) == .changed)
        precondition(ToolShortcuts.hotKey(for: rect, in: tools) == q)
        precondition(ToolShortcuts.change(ToolKind.oval.rawValue, to: q, in: tools) == .conflict(rect))
        precondition(ToolShortcuts.change(ToolShortcuts.select, to: press("o", kVK_ANSI_O, [])!, in: tools) == .conflict(ToolKind.oval.rawValue))
        precondition(ToolShortcuts.change(rect, to: press("1", kVK_ANSI_1, [])!, in: tools) == .reserved)
        precondition(ToolShortcuts.change(rect, to: press("x", kVK_ANSI_X, [.command])!, in: tools) == .needsPlainKey)
        precondition(ToolShortcuts.change(rect, to: press("r", kVK_ANSI_R, [])!, in: tools) == .changed)
        precondition(tools.dictionary(forKey: ToolShortcuts.preferenceKey)?[rect] == nil, "Default keys are not stored")
        // Toolbar actions may use modifiers, but not ⌘C/⌘W/zoom or another slot's key.
        let save = ToolShortcuts.Action.save.rawValue
        precondition(ToolShortcuts.hotKey(for: save, in: tools).symbol == "⌘S")
        let shiftCommandS = press("s", kVK_ANSI_S, [.command, .shift])!
        precondition(ToolShortcuts.change(save, to: shiftCommandS, in: tools) == .changed)
        precondition(ToolShortcuts.hotKey(for: save, in: tools) == shiftCommandS)
        precondition(ToolShortcuts.change(save, to: press("c", kVK_ANSI_C, [.command])!, in: tools) == .reserved)
        precondition(ToolShortcuts.change(save, to: press("z", kVK_ANSI_Z, [.command])!, in: tools) == .conflict(ToolShortcuts.Action.undo.rawValue))
        precondition(ToolShortcuts.change(save, to: press("v", kVK_ANSI_V, [])!, in: tools) == .conflict(ToolShortcuts.select))
        precondition(ToolShortcuts.change(ToolShortcuts.Action.cancel.rawValue, to: press("\u{1b}", kVK_Escape, [])!, in: tools) == .changed,
                     "A slot can always go back to its own default")
        ToolShortcuts.restoreDefaults(in: tools)
        precondition(ToolShortcuts.slots.allSatisfy { ToolShortcuts.hotKey(for: $0, in: tools) == ToolShortcuts.defaultHotKey(for: $0) })

        print("Passed hotkey checks: capture, ordering, validation, menu equivalents, persistence, toolbar keys")
    }
}
