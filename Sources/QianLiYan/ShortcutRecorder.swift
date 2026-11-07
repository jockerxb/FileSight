import AppKit

/// Records only while this control has focus; never monitors system-wide input.
final class ShortcutRecorder: NSButton {
    var shortcut: LauncherShortcut? { didSet { if !recording { showCurrent() } } }
    var onCommit: ((LauncherShortcut) -> Bool)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(equalToConstant: 106).isActive = true
        setAccessibilityLabel("呼出快捷键")
        showCurrent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    private func showCurrent() { title = shortcut?.label ?? "设置快捷键" }

    @objc private func beginRecording() {
        guard !recording, let window else { return }
        window.makeFirstResponder(self)
        recording = true
        title = "按下快捷键"
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type != .keyDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.cancelRecording()
                }
                return event
            }
            guard event.window === self.window else { self.cancelRecording(); return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && flags.intersection([.command, .option, .control, .shift]).isEmpty {
                self.cancelRecording()
                return nil
            }
            guard let next = LauncherShortcut.recorded(from: event) else {
                self.title = "需 ⌘ / ⌥ / ⌃"
                return nil
            }
            if self.onCommit?(next) == true {
                self.shortcut = next
                self.cancelRecording()
            } else {
                self.title = "已占用，请重试"
            }
            return nil
        }
    }

    func cancelRecording(clearFocus: Bool = true) {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        showCurrent()
        onRecording?(false)
        if clearFocus, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording(clearFocus: false)
        return super.resignFirstResponder()
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
