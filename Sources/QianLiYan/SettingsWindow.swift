import AppKit
import Carbon
import ServiceManagement

enum LoginLaunch {
    static var isLoginEvent: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}

private final class SettingsContentView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
        super.mouseDown(with: event)
    }
}

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let appearancePicker = NSPopUpButton()
    private let shortcutValue = ShortcutRecorder()
    private let loginSwitch = NSSwitch()
    private let loginHint = NSTextField(labelWithString: "登录后显示在菜单栏")
    private let loginSettings = NSButton()
    private let loginService = SMAppService.mainApp
    var onTheme: ((LauncherTheme) -> Void)?
    var onShortcut: ((LauncherShortcut) -> Bool)?
    var onRecording: ((Bool) -> Void)?
    var onDiagnostics: (() -> Void)?

    init(productTitle: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 466, height: 276),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "千里眼设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = SettingsContentView(frame: window.contentView!.frame)

        appearancePicker.addItems(withTitles: LauncherTheme.allCases.map(\.title))
        appearancePicker.setAccessibilityLabel("外观")
        appearancePicker.target = self; appearancePicker.action = #selector(selectTheme)
        shortcutValue.onCommit = { [weak self] in self?.onShortcut?($0) ?? false }
        shortcutValue.onRecording = { [weak self] in self?.onRecording?($0) }

        loginSwitch.setAccessibilityLabel("登录时启动")
        loginSwitch.target = self; loginSwitch.action = #selector(changeLoginItem)
        loginHint.font = .systemFont(ofSize: 11)
        loginHint.textColor = .secondaryLabelColor
        loginSettings.title = "打开登录项…"
        loginSettings.target = self; loginSettings.action = #selector(openLoginSettings)
        loginSettings.bezelStyle = .inline
        loginSettings.isHidden = true
        let loginLabel = NSStackView(views: [NSTextField(labelWithString: "登录时启动"), loginHint])
        loginLabel.orientation = .vertical; loginLabel.alignment = .leading; loginLabel.spacing = 3

        let diagnosticButton = NSButton(title: "搜索诊断…", target: self, action: #selector(showDiagnostics))
        let gitHub = NSButton(title: "查看 GitHub ↗", target: self, action: #selector(openGitHub))
        let version = NSTextField(labelWithString: productTitle)
        version.textColor = .secondaryLabelColor
        let divider = NSBox(); divider.boxType = .separator

        let rows = [
            Self.row([NSTextField(labelWithString: "外观"), NSView(), appearancePicker]),
            Self.row([NSTextField(labelWithString: "呼出快捷键"), NSView(), shortcutValue]),
            Self.row([loginLabel, NSView(), loginSettings, loginSwitch]),
            divider,
            Self.row([NSTextField(labelWithString: "索引与目录访问"), NSView(), diagnosticButton]),
            Self.row([version, NSView(), gitHub])
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // Size the window to its rows so the footer never leaves a fixed empty area.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 466, height: stack.fittingSize.height + 40))
        window.contentMinSize = window.contentView!.frame.size
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.alignment = .centerY; row.spacing = 8
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
    }

    func update(theme: LauncherTheme, shortcut: LauncherShortcut?) {
        appearancePicker.selectItem(at: theme.rawValue)
        shortcutValue.shortcut = shortcut
        refreshLoginItem()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshLoginItem() }

    private func refreshLoginItem() {
        let state = loginService.status
        loginSwitch.state = state == .enabled || state == .requiresApproval ? .on : .off
        loginSettings.isHidden = state != .requiresApproval
        loginHint.stringValue = state == .requiresApproval ? "需在系统设置中允许" : "登录后显示在菜单栏"
    }

    @objc private func changeLoginItem() {
        let enable = loginSwitch.state == .on
        let state = loginService.status
        defer { refreshLoginItem() }
        if enable ? (state == .enabled || state == .requiresApproval) : (state == .notRegistered || state == .notFound) { return }
        do {
            if enable { try loginService.register() } else { try loginService.unregister() }
        } catch {
            let actual = loginService.status
            if enable && actual == .requiresApproval { return }
            guard let window else { return }
            let dialog = NSAlert()
            dialog.messageText = enable ? "无法开启登录启动" : "无法关闭登录启动"
            dialog.informativeText = error.localizedDescription
            dialog.beginSheetModal(for: window)
        }
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func selectTheme() {
        if let theme = LauncherTheme(rawValue: appearancePicker.indexOfSelectedItem) { onTheme?(theme) }
    }
    func windowDidResignKey(_ notification: Notification) { shortcutValue.cancelRecording() }
    func windowWillClose(_ notification: Notification) { shortcutValue.cancelRecording() }
    @objc private func showDiagnostics() { onDiagnostics?() }
    @objc private func openGitHub() {
        // Hand only the fixed project URL to the user's browser.
        guard let url = URL(string: "https://github.com/jockerxb/FileSight") else { return }
        NSWorkspace.shared.open(url)
    }
}
