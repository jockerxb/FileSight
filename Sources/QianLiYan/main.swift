import AppKit
import SearchCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSWindowDelegate {
    let index = FileIndex()
    let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 210), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let field = NSTextField()
    let scope = LauncherDropdown(label: "搜索范围", titles: Scope.allCases.map(\.title))
    let sort = LauncherDropdown(label: "排序方式", titles: AppDelegate.orderTitles)
    let logo = NSImageView(image: Branding.mark())
    let direction = NSButton()
    let status = NSTextField(labelWithString: "")
    let authorize = NSButton()
    let summary = NSTextField(labelWithString: "")
    let countRow = NSStackView()
    let table = NSTableView()
    let results = NSScrollView()
    let more = NSButton(title: "继续显示", target: nil, action: nil)
    let body = NSView()
    let hotkey = LauncherHotKey()
    var statusItem: NSStatusItem!
    var activeShortcut: LauncherShortcut?
    var editingShortcut = false
    var settings: SettingsWindow?
    enum Scope: Int, CaseIterable {
        case downloads, custom
        var title: String { self == .downloads ? "下载" : "选择目录…" }
    }
    let downloads = LocalFiles.userHome.appendingPathComponent("Downloads", isDirectory: true)
    var selectedScope: Scope = .downloads
    var roots: [ScanRoot] = []
    var rows: [FileEntry] = []
    var totalMatches = 0
    var order = SearchOrder.relevance
    var ascending = true
    var limit = 100
    var timer: Timer?
    var pending: DispatchWorkItem?
    var token = SearchCancellation()
    var requestID = 0
    var scanGeneration = 0
    var searchBusy = false
    var appliedKey = ""
    var shownRevision = -1
    var lastAutomatic = Date.distantPast
    let searchQueue = DispatchQueue(label: "qianliyan.quick-search", qos: .userInitiated)
    let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy/MM/dd HH:mm"; return f
    }()
    var productTitle: String { "千里眼 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1")" }
    static let orderTitles = ["名称优先", "修改时间", "创建时间", "文件类型", "文件名"]
    var theme = LauncherTheme(rawValue: UserDefaults.standard.integer(forKey: LauncherTheme.preferenceKey)) ?? .dark

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildApplicationMenu()
        buildPanel()
        buildStatusItem()
        hotkey.action = { [weak self] in
            guard let self, !self.editingShortcut else { return }
            self.togglePanel()
        }
        let saved = UserDefaults.standard.data(forKey: LauncherShortcut.preferenceKey)
            .flatMap { try? JSONDecoder().decode(LauncherShortcut.self, from: $0) }
        let preferred = saved.flatMap { $0.isValid ? $0 : nil } ?? .defaultShortcut
        if hotkey.register(preferred) { activeShortcut = preferred }
        if !LoginLaunch.isLoginEvent { showPanel() }
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in self?.pollIndex() }
    }

    func buildApplicationMenu() {
        let main = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu(); main.addItem(root)
        root.submenu?.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        root.submenu?.addItem(withTitle: "退出千里眼", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑"); editItem.submenu = edit; main.addItem(editItem)
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let searchItem = NSMenuItem(); let menu = NSMenu(title: "搜索"); searchItem.submenu = menu; main.addItem(searchItem)
        menu.addItem(withTitle: "呼出搜索", action: #selector(showPanel), keyEquivalent: "f").target = self
        menu.addItem(withTitle: "刷新索引", action: #selector(rescan), keyEquivalent: "r").target = self
        let copy = menu.addItem(withTitle: "复制完整路径", action: #selector(copyPath), keyEquivalent: "c"); copy.keyEquivalentModifierMask = [.command, .shift]; copy.target = self
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Branding.mark()
            button.image?.isTemplate = true
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("千里眼菜单栏")
            button.toolTip = "千里眼 · 右键打开菜单"
        }
    }

    func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title; button.target = self; button.action = action
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    func buildPanel() {
        panel.title = "千里眼 · 快速搜索"
        panel.delegate = self
        panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let effect = NSView()
        effect.wantsLayer = true; effect.layer?.cornerRadius = 19; effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        panel.contentView = effect
        let top = NSView()
        logo.imageScaling = .scaleProportionallyUpOrDown
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 27, weight: .regular); field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(string: "搜索本地文件…", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 27, weight: .regular)])
        field.delegate = self; field.setAccessibilityLabel("搜索文件名")
        for view in [logo, field] { top.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 24), logo.centerYAnchor.constraint(equalTo: top.centerYAnchor), logo.widthAnchor.constraint(equalToConstant: 34), logo.heightAnchor.constraint(equalTo: logo.widthAnchor),
            field.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 13), field.centerYAnchor.constraint(equalTo: top.centerYAnchor), field.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -24), field.heightAnchor.constraint(equalToConstant: 40)
        ])
        top.heightAnchor.constraint(equalToConstant: 82).isActive = true
        scope.onSelection = { [weak self] in self?.scopeChanged() }
        scope.toolTip = roots.map(\.path).joined(separator: "；")
        sort.onSelection = { [weak self] in self?.sortChanged() }
        configure(direction, title: "", action: #selector(toggleDirection))
        updateDirection()
        configure(authorize, title: "授权下载…", action: #selector(authorizeDownloads))
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.isHidden = true
        let controls = NSStackView(views: [scope, authorize, status, NSView(), sort, direction])
        controls.spacing = 8; controls.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 20)
        controls.heightAnchor.constraint(equalToConstant: 35).isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); table.addTableColumn(column)
        table.style = .plain
        table.headerView = nil; table.rowHeight = 66; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular; table.focusRingType = .none
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(revealSelected)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let actions = NSMenu()
        actions.addItem(withTitle: "在 Finder 中显示", action: #selector(revealSelected), keyEquivalent: "").target = self
        actions.addItem(withTitle: "复制完整路径", action: #selector(copyPath), keyEquivalent: "").target = self
        actions.delegate = self; table.menu = actions
        results.documentView = table; results.drawsBackground = false; results.hasVerticalScroller = true; results.autohidesScrollers = true
        results.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(results)
        NSLayoutConstraint.activate([
            results.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10), results.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10), results.topAnchor.constraint(equalTo: body.topAnchor, constant: 5), results.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        configure(more, title: "再显示 100 项", action: #selector(showMore))
        more.isHidden = true
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); summary.textColor = .secondaryLabelColor
        for view in [summary, NSView(), more] { countRow.addArrangedSubview(view) }
        countRow.edgeInsets = NSEdgeInsets(top: 0, left: 23, bottom: 0, right: 22); countRow.heightAnchor.constraint(equalToConstant: 29).isActive = true
        let stack = NSStackView(views: [top, divider(), controls, body, countRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor), stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        for view in stack.views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.isHidden = true
        countRow.isHidden = true
        applyTheme()
    }

    func applyTheme() {
        panel.appearance = theme.appearance
        panel.contentView?.layer?.backgroundColor = theme.background.cgColor
        panel.contentView?.layer?.borderColor = theme.border.cgColor
        logo.contentTintColor = theme.brand
        table.needsDisplay = true
    }

    func divider() -> NSView { let v = NSBox(); v.boxType = .separator; v.heightAnchor.constraint(equalToConstant: 1).isActive = true; return v }

    @objc func showPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let height = desiredPanelHeight
        panel.setFrame(NSRect(x: area.midX - 390, y: area.maxY - height - max(65, area.height * 0.14), width: 780, height: min(height, area.height - 100)), display: true)
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); panel.makeFirstResponder(field)
        pollIndex()
    }
    @objc func togglePanel() { panel.isVisible ? panel.orderOut(nil) : showPanel() }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true { showStatusMenu() }
        else { togglePanel() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.orderOut(nil); return false }
    func controlTextDidChange(_ obj: Notification) { requestSearch(resetLimit: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil); return true
        case #selector(NSResponder.moveDown(_:)): selectOffset(1); return true
        case #selector(NSResponder.moveUp(_:)): selectOffset(-1); return true
        case #selector(NSResponder.insertNewline(_:)): revealSelected(); return true
        default: return false
        }
    }
    func selectOffset(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let row = max(0, min(rows.count - 1, table.selectedRow < 0 ? 0 : table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    func requestSearch(resetLimit: Bool) {
        if resetLimit { limit = 100 }
        requestID += 1; token.cancel(); token = SearchCancellation(); pending?.cancel(); searchBusy = false
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchBusy = false
            rows = []; totalMatches = 0; table.reloadData(); appliedKey = ""
            updateSearchDisplay(message: "")
            return
        }
        if resetLimit { rows = []; totalMatches = 0; table.reloadData() }
        updateSearchDisplay(message: "搜索中…", loading: true)
        let work = DispatchWorkItem { [weak self] in self?.performSearch() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }
    var desiredPanelHeight: CGFloat {
        // Search bar, controls, and their separator.
        let chrome: CGFloat = 82 + 35 + 1
        let list = body.isHidden ? 0 : 5 + CGFloat(min(rows.count, 7)) * table.rowHeight
        return chrome + list + (countRow.isHidden ? 0 : 29)
    }
    func resizePanel() {
        guard panel.isVisible else { return }
        let target = desiredPanelHeight
        let area = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = min(target, area.height - 100)
        var frame = panel.frame
        if abs(frame.height - height) > 1 { frame.origin.y += frame.height - height; frame.size.height = height; panel.setFrame(frame, display: true, animate: false) }
    }
    func searchKey(_ view: IndexView) -> String { "\(scanGeneration)|\(view.revision)|\(field.stringValue)|\(order.rawValue)|\(ascending)|\(limit)" }
    func performSearch() {
        guard !searchBusy else { return }
        let view = index.view()
        let key = searchKey(view)
        guard !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key != appliedKey else { return }
        let id = requestID, generation = scanGeneration, query = field.stringValue, sortOrder = order, asc = ascending, pageLimit = limit, cancellation = token
        searchBusy = true
        searchQueue.async { [weak self] in
            let output = QuickSearch.search(pages: view.pages, query: query, order: sortOrder, ascending: asc, limit: pageLimit, cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self, id == self.requestID, generation == self.scanGeneration, !cancellation.cancelled, let output else { return }
                self.searchBusy = false; self.appliedKey = key
                let selected = self.selectedEntry?.path
                self.rows = output.rows; self.totalMatches = output.total; self.table.reloadData()
                let selection = selected.flatMap { path in self.rows.firstIndex(where: { $0.path == path }) } ?? 0
                if !self.rows.isEmpty { self.table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
                self.updateSearchDisplay(message: output.rows.isEmpty
                    ? (self.roots.isEmpty ? "授权目录后搜索" : view.scanning ? "暂未找到匹配项" : "没有匹配项")
                    : "\(output.total.formatted()) 项")
            }
        }
    }
    func updateSearchDisplay(message: String, loading: Bool = false) {
        summary.stringValue = message
        body.isHidden = rows.isEmpty
        countRow.isHidden = message.isEmpty
        more.isHidden = rows.count >= totalMatches || loading
        resizePanel()
    }
    func pollIndex() {
        let view = index.view()
        if shownRevision != view.revision {
            shownRevision = view.revision
            status.stringValue = view.scanning ? "扫描中…" : view.errorCount > 0 ? "部分目录未读取" : ""
            status.isHidden = status.stringValue.isEmpty
        }
        guard panel.isVisible, !searchBusy, !field.stringValue.isEmpty, searchKey(view) != appliedKey, Date().timeIntervalSince(lastAutomatic) >= 1.2 else { return }
        lastAutomatic = Date(); performSearch()
    }
    @objc func sortChanged() {
        order = SearchOrder(rawValue: sort.indexOfSelectedItem) ?? .relevance
        ascending = order == .relevance || order == .kind || order == .name
        updateDirection(); requestSearch(resetLimit: true)
    }
    @objc func toggleDirection() { guard order != .relevance else { return }; ascending.toggle(); updateDirection(); requestSearch(resetLimit: true) }
    func updateDirection() {
        direction.isHidden = order == .relevance
        switch order {
        case .relevance: break
        case .modified, .created: direction.title = ascending ? "↑ 最早在前" : "↓ 最新在前"
        case .kind, .name: direction.title = ascending ? "↑ A–Z" : "↓ Z–A"
        }
        sort.toolTip = order == .kind ? "按扩展名分组，同类型内最近修改的文件在前" : order == .relevance ? "完整名称优先，其次开头匹配，再按最近修改排列" : nil
    }
    @objc func showMore() { limit += 100; requestSearch(resetLimit: false) }
    @objc func scopeChanged() {
        guard let next = Scope(rawValue: scope.indexOfSelectedItem) else { return }
        if next == .downloads {
            if selectedScope != .downloads || roots.isEmpty { authorizeDownloads() }
        } else { chooseFolders() }
    }
    @objc func authorizeDownloads() { pickFolders(for: .downloads) }
    @objc func chooseFolders() { pickFolders(for: .custom) }
    private func pickFolders(for requested: Scope) {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false; dialog.canChooseDirectories = true
        dialog.canCreateDirectories = false; dialog.allowsMultipleSelection = requested == .custom
        dialog.directoryURL = downloads
        dialog.prompt = "授权只读"
        dialog.message = "只搜索你选中的本地目录。退出后不保留目录授权和索引。"
        if dialog.runModal() == .OK {
            do {
                let selected = try dialog.urls.map(ScanRoot.authorized)
                selectedScope = requested == .downloads && selected.count == 1 && selected[0].path == FileIndex.canonicalRoot(downloads).path
                    ? .downloads : .custom
                roots = selected
                rescan()
            } catch {
                alert("无法授权目录", "请选择可读取的本地文件夹；未更改原有搜索范围。")
            }
        }
        scope.selectItem(at: selectedScope.rawValue)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
    }
    @objc func rescan() {
        requestID += 1; scanGeneration += 1; token.cancel(); token = SearchCancellation(); pending?.cancel(); searchBusy = false; appliedKey = ""; shownRevision = -1
        index.start(authorizedRoots: roots)
        authorize.isHidden = !roots.isEmpty
        scope.toolTip = roots.isEmpty ? "尚未授权目录" : roots.map(\.path).joined(separator: "；")
        rows = []; table.reloadData()
        if !field.stringValue.isEmpty { requestSearch(resetLimit: true) }
        pollIndex()
    }
    var selectedEntry: FileEntry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    @objc func revealSelected() {
        guard let entry = selectedEntry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]); panel.orderOut(nil)
    }
    @objc func copyPath() {
        guard let entry = selectedEntry else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string)
        summary.stringValue = "已复制路径"
    }
    func menuNeedsUpdate(_ menu: NSMenu) { if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) } }
    func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "呼出搜索  \(activeShortcut?.label ?? "菜单栏")", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出千里眼", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: .zero, in: button)
    }
    @objc func showSettings() {
        if settings == nil {
            let controller = SettingsWindow(productTitle: productTitle)
            controller.onTheme = { [weak self] selected in
                guard let self else { return }
                self.theme = selected
                UserDefaults.standard.set(selected.rawValue, forKey: LauncherTheme.preferenceKey)
                self.applyTheme()
            }
            controller.onShortcut = { [weak self] in self?.saveShortcut($0) ?? false }
            controller.onRecording = { [weak self] recording in
                guard let self else { return }
                self.editingShortcut = recording
                if recording { self.hotkey.suspend() }
                else if let shortcut = self.activeShortcut { self.hotkey.resume(shortcut) }
            }
            controller.onDiagnostics = { [weak self] in self?.showIssues() }
            settings = controller
        }
        panel.orderOut(nil)
        settings?.update(theme: theme, shortcut: activeShortcut)
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
    func saveShortcut(_ next: LauncherShortcut) -> Bool {
        guard hotkey.register(next) else { return false }
        activeShortcut = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: LauncherShortcut.preferenceKey)
        }
        return true
    }
    func showIssues() {
        guard let window = settings?.window else { return }
        let view = index.view()
        let dialog = NSAlert()
        dialog.messageText = "搜索诊断"
        if roots.isEmpty {
            dialog.informativeText = "尚未授权目录。请先从搜索面板选择目录。"
        } else {
            let state = view.scanning ? "正在更新" : view.errorCount > 0 ? "有访问提示" : "索引已就绪"
            dialog.informativeText = "\(state) · 已收录 \(view.count.formatted()) 项"
        }
        dialog.addButton(withTitle: "完成")
        let canRefresh = !roots.isEmpty && !view.scanning
        if canRefresh { dialog.addButton(withTitle: "刷新索引") }
        if !roots.isEmpty {
            let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 395, height: 125))
            details.isEditable = false; details.font = .systemFont(ofSize: 12)
            let issues = view.errorCount > 0 ? "\n\n访问提示（\(view.errorCount) 处）\n" + view.errors.joined(separator: "\n") : ""
            details.string = "搜索范围\n" + roots.map(\.path).joined(separator: "\n") + issues
            details.isVerticallyResizable = true; details.autoresizingMask = [.width]
            let scroll = NSScrollView(frame: details.frame)
            scroll.documentView = details; scroll.hasVerticalScroller = true
            dialog.accessoryView = scroll
        }
        dialog.beginSheetModal(for: window) { [weak self] response in
            if canRefresh && response == .alertSecondButtonReturn { self?.rescan() }
        }
    }
    func alert(_ title: String, _ detail: String) { let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.runModal() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("result-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCell ?? ResultCell(frame: .zero)
        cell.identifier = identifier
        let date = order == .created ? rows[row].created : rows[row].modified
        cell.show(rows[row], date: date == .distantPast ? "时间未知" : formatter.string(from: date))
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
