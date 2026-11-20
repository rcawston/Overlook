import AppKit
import Carbon

/// Actions that send keys to the remote computer from a local shortcut while keyboard
/// capture is active, for keys a Mac keyboard cannot produce or that macOS intercepts.
enum RemoteKeyboardAction: String, CaseIterable, Identifiable {
    case insert
    case ctrlAltDelete
    case paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insert: return "Insert"
        case .ctrlAltDelete: return "Ctrl+Alt+Delete"
        case .paste: return "Paste clipboard as text"
        }
    }

    var defaultShortcut: RemoteKeyboardShortcut {
        switch self {
        case .insert:
            // The key directly left of Backspace: `=` on US, `´` on German keyboards.
            return RemoteKeyboardShortcut(keyCode: UInt16(kVK_ANSI_Equal), modifiers: [.command])
        case .ctrlAltDelete:
            return RemoteKeyboardShortcut(keyCode: UInt16(kVK_Delete), modifiers: [.command, .option])
        case .paste:
            return RemoteKeyboardShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command])
        }
    }

    /// HID key names pressed in this order and released in reverse. Empty for paste, which
    /// types the clipboard through the device's text API instead.
    var remoteKeys: [String] {
        switch self {
        case .insert: return ["Insert"]
        case .ctrlAltDelete: return ["ControlLeft", "AltLeft", "Delete"]
        case .paste: return []
        }
    }
}

/// A local shortcut: a physical key (layout independent) plus the exact modifiers.
struct RemoteKeyboardShortcut: Codable, Hashable {
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let keyCode: UInt16
    private let modifierFlags: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.relevantModifiers)
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers.intersection(Self.relevantModifiers)
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    /// The key's label on the current keyboard layout, e.g. `´` or `=` for the same key.
    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Help: return "Help"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            break
        }
        if let character = layoutCharacter(for: keyCode), !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            let maxLength = 4
            var length = 0
            var characters = [UniChar](repeating: 0, count: maxLength)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                maxLength,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: characters, count: length)
            return string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
    }
}

/// The shortcut of every remote keyboard action, shared by all devices and stored in
/// UserDefaults. A missing entry uses the default; `nil` means the action is disabled.
struct RemoteKeyboardShortcuts: Equatable {
    private static let defaultsKey = "overlook.remoteKeyboardShortcuts"

    private var overrides: [RemoteKeyboardAction: RemoteKeyboardShortcut?] = [:]

    subscript(action: RemoteKeyboardAction) -> RemoteKeyboardShortcut? {
        if let override = overrides[action] {
            return override
        }
        return action.defaultShortcut
    }

    func action(forKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> RemoteKeyboardAction? {
        RemoteKeyboardAction.allCases.first { self[$0]?.matches(keyCode: keyCode, modifiers: modifiers) == true }
    }

    /// Returns why `shortcut` cannot be used for `action`, or `nil` if it can.
    func validationError(for shortcut: RemoteKeyboardShortcut, action: RemoteKeyboardAction) -> String? {
        let modifiers = shortcut.modifiers
        if modifiers.intersection([.command, .control, .option]).isEmpty {
            return "Use Command, Control or Option in the shortcut."
        }
        if let reason = Self.reservedReason(for: shortcut) {
            return "\(shortcut.displayString) is reserved \(reason)."
        }
        if let other = RemoteKeyboardAction.allCases.first(where: { $0 != action && self[$0] == shortcut }) {
            return "\(shortcut.displayString) is already used for \(other.title)."
        }
        return nil
    }

    /// Shortcuts that Overlook already uses itself.
    private static func reservedReason(for shortcut: RemoteKeyboardShortcut) -> String? {
        let keyCode = Int(shortcut.keyCode)
        let modifiers = shortcut.modifiers
        if modifiers == [.command] {
            switch keyCode {
            case kVK_ANSI_C: return "for OCR mode"
            case kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_Comma, kVK_ANSI_H, kVK_ANSI_M: return "by the app"
            default: break
            }
        }
        // The menu bar agent reacts to these whenever Command and Shift are held.
        if modifiers.isSuperset(of: [.command, .shift]),
           [kVK_ANSI_V, kVK_ANSI_O, kVK_ANSI_R].contains(keyCode) {
            return "as a global menu bar shortcut"
        }
        return nil
    }

    mutating func set(_ shortcut: RemoteKeyboardShortcut?, for action: RemoteKeyboardAction) {
        if shortcut == action.defaultShortcut {
            overrides[action] = nil
        } else {
            overrides[action] = .some(shortcut)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> RemoteKeyboardShortcuts {
        var result = RemoteKeyboardShortcuts()
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: RemoteKeyboardShortcut?].self, from: data) else {
            return result
        }
        for (key, shortcut) in stored {
            guard let action = RemoteKeyboardAction(rawValue: key) else { continue }
            result.overrides[action] = .some(shortcut)
        }
        return result
    }

    func save(to defaults: UserDefaults = .standard) {
        var stored: [String: RemoteKeyboardShortcut?] = [:]
        for (action, shortcut) in overrides {
            stored[action.rawValue] = .some(shortcut)
        }
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
