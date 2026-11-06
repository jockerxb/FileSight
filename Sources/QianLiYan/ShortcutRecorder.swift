import AppKit

enum ShortcutRecorder {
    static func choose(current: LauncherShortcut?) -> LauncherShortcut? {
        let dialog = NSAlert()
        dialog.messageText = "设置呼出快捷键"
        dialog.informativeText = "直接按下组合键。请使用 ⌘、⌥ 或 ⌃ 加上一个按键。"
        let save = dialog.addButton(withTitle: "保存")
        save.isEnabled = false
        dialog.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        dialog.addButton(withTitle: "恢复默认 ⌘↑")
        let preview = NSTextField(labelWithString: current.map { "当前：\($0.label)" } ?? "当前：从菜单栏呼出")
        preview.font = .systemFont(ofSize: 18, weight: .medium)
        preview.frame = NSRect(x: 0, y: 0, width: 295, height: 28)
        preview.setAccessibilityLabel("快捷键预览")
        dialog.accessoryView = preview

        var captured: LauncherShortcut?
        let window = dialog.window
        // This monitor receives only this dialog's key events and is removed
        // before the dialog returns. No system-wide input monitor is needed.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else { return event }
            guard let shortcut = LauncherShortcut.recorded(from: event) else { return event }
            captured = shortcut
            preview.stringValue = "新快捷键：\(shortcut.label)"
            save.isEnabled = true
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        switch dialog.runModal() {
        case .alertFirstButtonReturn: return captured
        case .alertThirdButtonReturn: return .defaultShortcut
        default: return nil
        }
    }
}
