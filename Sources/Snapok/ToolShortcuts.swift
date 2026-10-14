import AppKit
import Carbon

/// The capture toolbar's shortcuts, customizable in settings. Tool slots ("select" and `ToolKind` raw values) take
/// one key without modifiers; action slots (`ToolShortcuts.Action`) may use modifiers.
enum ToolShortcuts {
    static let preferenceKey = "editor.toolShortcuts"
    static let didChange = Notification.Name("ToolShortcuts.didChange")
    static let select = "select"

    /// The toolbar's buttons after the tools, in toolbar order.
    enum Action: String, CaseIterable {
        case undo, pin, save, scroll, editImage, cancel, done

        var title: String {
            switch self {
            case .undo: return L("Undo", "撤销")
            case .pin: return L("Pin to Screen", "钉在屏幕上")
            case .save: return L("Save", "保存")
            case .scroll: return L("Scrolling Capture", "长截图")
            case .editImage: return L("Edit Image", "编辑图片")
            case .cancel: return L("Cancel Capture", "退出截图")
            case .done: return L("Done and Copy", "完成并复制")
            }
        }
    }

    static var toolSlots: [String] { [select] + ToolKind.allCases.map(\.rawValue) }
    static var actionSlots: [String] { Action.allCases.map(\.rawValue) }
    static var slots: [String] { toolSlots + actionSlots }

    private static func key(_ code: Int, _ name: String, _ modifiers: Int = 0) -> HotKey {
        HotKey(keyCode: UInt32(code), modifiers: UInt32(modifiers), key: name)
    }

    static func defaultHotKey(for slot: String) -> HotKey {
        switch slot {
        case select: return key(kVK_ANSI_V, "V")
        case ToolKind.rect.rawValue: return key(kVK_ANSI_R, "R")
        case ToolKind.oval.rawValue: return key(kVK_ANSI_O, "O")
        case ToolKind.arrow.rawValue: return key(kVK_ANSI_A, "A")
        case ToolKind.pen.rawValue: return key(kVK_ANSI_P, "P")
        case ToolKind.mosaic.rawValue: return key(kVK_ANSI_M, "M")
        case ToolKind.text.rawValue: return key(kVK_ANSI_T, "T")
        case ToolKind.step.rawValue: return key(kVK_ANSI_N, "N")
        case ToolKind.erase.rawValue: return key(kVK_ANSI_E, "E")
        case Action.undo.rawValue: return key(kVK_ANSI_Z, "Z", cmdKey)
        case Action.pin.rawValue: return key(kVK_ANSI_T, "T", cmdKey)
        case Action.save.rawValue: return key(kVK_ANSI_S, "S", cmdKey)
        case Action.scroll.rawValue: return key(kVK_ANSI_L, "L", cmdKey)
        case Action.editImage.rawValue: return AppChannel.editImageHotKey(forRelease: AppChannel.isRelease)
        case Action.cancel.rawValue: return key(kVK_Escape, "⎋")
        case Action.done.rawValue: return key(kVK_Return, "↩")
        default: return key(0, "")
        }
    }

    /// Plain keys the editors already use: sizes 1–3, [ ], and Esc, Enter, Delete, Space, Tab, arrows.
    private static let reservedPlain: Set<Int> = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete, kVK_Space, kVK_Tab,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow
    ]
    /// ⌘ shortcuts with fixed meanings: copy, close, quit, and zoom.
    private static let reservedCommand: Set<Int> = [kVK_ANSI_C, kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_0]

    static func hotKey(for slot: String, in store: UserDefaults = .standard) -> HotKey {
        guard let saved = store.dictionary(forKey: preferenceKey)?[slot] as? [String: Any],
              let code = saved["keyCode"] as? Int, let key = saved["key"] as? String, !key.isEmpty else {
            return defaultHotKey(for: slot)
        }
        return HotKey(keyCode: UInt32(code), modifiers: UInt32(saved["modifiers"] as? Int ?? 0), key: key)
    }

    static var selectKeyCode: UInt16 { UInt16(hotKey(for: select).keyCode) }

    /// Whether a key press is this slot's shortcut.
    static func matches(_ slot: String, _ event: NSEvent) -> Bool {
        guard let pressed = HotKey(event: event) else { return false }
        let shortcut = hotKey(for: slot)
        return pressed.keyCode == shortcut.keyCode && pressed.modifiers == shortcut.modifiers
    }

    static func matches(_ action: Action, _ event: NSEvent) -> Bool { matches(action.rawValue, event) }

    static func symbol(_ action: Action) -> String { hotKey(for: action.rawValue).symbol }

    enum ChangeResult: Equatable { case changed, needsPlainKey, reserved, conflict(String) }

    static func change(_ slot: String, to hotKey: HotKey, in store: UserDefaults = .standard) -> ChangeResult {
        let isTool = toolSlots.contains(slot)
        if isTool, hotKey.modifiers != 0 || hotKey.key.count != 1 { return .needsPlainKey }
        let plain = hotKey.modifiers == 0, commandOnly = hotKey.modifiers == UInt32(cmdKey)
        let ownDefault = hotKey == defaultHotKey(for: slot)
        if !ownDefault, (plain && reservedPlain.contains(Int(hotKey.keyCode))) || (commandOnly && reservedCommand.contains(Int(hotKey.keyCode))) {
            return .reserved
        }
        if let other = slots.first(where: {
            $0 != slot && self.hotKey(for: $0, in: store).keyCode == hotKey.keyCode && self.hotKey(for: $0, in: store).modifiers == hotKey.modifiers
        }) {
            return .conflict(other)
        }
        var saved = store.dictionary(forKey: preferenceKey) ?? [:]
        saved[slot] = ownDefault ? nil : ["keyCode": Int(hotKey.keyCode), "modifiers": Int(hotKey.modifiers), "key": hotKey.key]
        store.set(saved, forKey: preferenceKey)
        NotificationCenter.default.post(name: didChange, object: nil)
        return .changed
    }

    /// Puts every slot back on its default key.
    static func restoreDefaults(in store: UserDefaults = .standard) {
        store.removeObject(forKey: preferenceKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var isDefault: Bool { slots.allSatisfy { hotKey(for: $0) == defaultHotKey(for: $0) } }

    static func title(for slot: String) -> String {
        if slot == select { return L("Select / Move", "选择 / 移动") }
        return ToolKind(rawValue: slot)?.title ?? Action(rawValue: slot)?.title ?? slot
    }
}
