import AppKit
import Carbon

struct LauncherShortcut: Codable {
    let keyCode: UInt16
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = Self(keyCode: UInt16(kVK_UpArrow), modifiers: UInt32(cmdKey), keyLabel: "↑")
    private static let requiredModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let preferenceKey = "launcherShortcutBinding"

    var isValid: Bool {
        modifiers & Self.requiredModifiers != 0 && modifiers & ~Self.supportedModifiers == 0 &&
            keyCode < 128 && !keyLabel.isEmpty && keyLabel.count <= 8
    }

    var label: String {
        let flags = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return flags.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyLabel
    }

    func matches(_ other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    static func recorded(from event: NSEvent) -> Self? {
        let flags = event.modifierFlags
        let pairs: [(NSEvent.ModifierFlags, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        let modifiers = pairs.reduce(UInt32(0)) { $0 | (flags.contains($1.0) ? UInt32($1.1) : 0) }
        let special: [Int: String] = [
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Space: "空格", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Escape: "Esc"
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let code = Int(event.keyCode)
        let text = special[code] ?? functionKeys.firstIndex(of: code).map { "F\($0 + 1)" } ??
            event.charactersIgnoringModifiers?.uppercased()
        guard let text, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xE000...0xF8FF).contains($0.value) }) else { return nil }
        let shortcut = Self(keyCode: event.keyCode, modifiers: modifiers, keyLabel: text)
        return shortcut.isValid ? shortcut : nil
    }
}

final class LauncherHotKey {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    var action: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<LauncherHotKey>.fromOpaque(context).takeUnretainedValue()
            owner.action?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: LauncherShortcut) -> Bool {
        // Keep the existing binding until the replacement has registered.
        guard handler != nil, shortcut.isValid else { return false }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers,
            EventHotKeyID(signature: 0x514C5953, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &next)
        guard result == noErr, let next else { return false }
        if let registration { UnregisterEventHotKey(registration) }
        registration = next
        return true
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }
}
