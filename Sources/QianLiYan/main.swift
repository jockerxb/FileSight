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
    enum Scope: Int, CaseIterable {
        case downloads, home, disks, custom
        var title: String {
            switch self {
            case .downloads: "下载"
            case .home: "个人目录"
            case .disks: "本机本地磁盘"
            case .custom: "选择目录…"
            }
        }
        var roots: [URL] {
            switch self {
            case .downloads: [LocalFiles.userHome.appendingPathComponent("Downloads", isDirectory: true)]
            case .home: [LocalFiles.userHome]
            case .disks: [URL(fileURLWithPath: "/", isDirectory: true)]
            case .custom: []
            }
        }
    }
    var selectedScope: Scope = .downloads
    var roots = Scope.downloads.roots
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
        showPanel()
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in self?.pollIndex() }
    }

    func buildApplicationMenu() {
        let main = NSMenu()
        let root = NSMenuItem(); root.submenu = NSMenu(); main.addItem(root)
        root.submenu?.addItem(withTitle: "退出千里眼", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑"); editItem.submenu = edit; main.addItem(editItem)
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let searchItem = NSMenuItem(); let menu = NSMenu(title: "搜索"); searchItem.submenu = menu; main.addItem(searchItem)
        menu.addItem(withTitle: "呼出搜索", action: #selector(showPanel), keyEquivalent: "f").target = self
        menu.addItem(withTitle: "重新扫描", action: #selector(rescan), keyEquivalent: "r").target = self
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
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.isHidden = true
        let controls = NSStackView(views: [scope, status, NSView(), sort, direction])
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
    func searchKey(_ view: IndexView) -> String { "\(scanGeneration)|\(view.count)|\(field.stringValue)|\(order.rawValue)|\(ascending)|\(limit)" }
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
                    ? (view.scanning ? "暂未找到匹配项" : "没有匹配项")
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
        if next == .custom { chooseFolders(); return }
        selectedScope = next; roots = next.roots; rescan()
    }
    @objc func chooseFolders() {
        let dialog = NSOpenPanel(); dialog.canChooseFiles = false; dialog.canChooseDirectories = true; dialog.canCreateDirectories = false; dialog.allowsMultipleSelection = true
        dialog.prompt = "搜索这些目录"; dialog.message = "只读本地文件名。不会上传、编辑或删除文件。"
        if dialog.runModal() == .OK {
            selectedScope = .custom; roots = dialog.urls; rescan()
        }
        scope.selectItem(at: selectedScope.rawValue)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
    }
    @objc func rescan() {
        requestID += 1; scanGeneration += 1; token.cancel(); token = SearchCancellation(); pending?.cancel(); searchBusy = false; appliedKey = ""; shownRevision = -1
        index.start(roots: roots)
        scope.toolTip = roots.map(\.path).joined(separator: "；")
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
        menu.addItem(withTitle: "设置呼出快捷键…", action: #selector(editShortcut), keyEquivalent: "").target = self
        let appearance = NSMenu(title: "外观")
        for value in LauncherTheme.allCases {
            let item = appearance.addItem(withTitle: value.title, action: #selector(changeTheme(_:)), keyEquivalent: "")
            item.target = self; item.tag = value.rawValue; item.state = value == theme ? .on : .off
        }
        let appearanceRoot = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        appearanceRoot.submenu = appearance; menu.addItem(appearanceRoot)
        let sorting = NSMenu(title: "默认排序")
        for value in SearchOrder.allCases {
            let item = sorting.addItem(withTitle: Self.orderTitles[value.rawValue], action: #selector(changeSortFromMenu(_:)), keyEquivalent: ""); item.target = self; item.tag = value.rawValue; item.state = value == order ? .on : .off
        }
        let sortRoot = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: ""); sortRoot.submenu = sorting; menu.addItem(sortRoot)
        menu.addItem(withTitle: "选择搜索目录…", action: #selector(chooseFolders), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新扫描本地目录", action: #selector(rescan), keyEquivalent: "").target = self
        menu.addItem(withTitle: "索引状态与访问详情…", action: #selector(showIssues), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let view = index.view()
        let state = NSMenuItem(title: "本地只读 · 已收录 \(view.count.formatted()) 项", action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        menu.addItem(withTitle: "关于千里眼 2.0", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出千里眼", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: .zero, in: button)
    }
    @objc func changeTheme(_ sender: NSMenuItem) {
        guard let selected = LauncherTheme(rawValue: sender.tag) else { return }
        theme = selected
        UserDefaults.standard.set(selected.rawValue, forKey: LauncherTheme.preferenceKey)
        applyTheme()
        if !panel.isVisible { showPanel() }
    }
    @objc func editShortcut() {
        guard !editingShortcut else { return }
        editingShortcut = true
        defer { editingShortcut = false }
        NSApp.activate(ignoringOtherApps: true)
        guard let next = ShortcutRecorder.choose(current: activeShortcut) else { return }
        guard activeShortcut?.matches(next) == true || hotkey.register(next) else {
            alert("无法注册快捷键", "\(next.label) 可能已被系统或其他应用占用。当前设置保持不变，请试另一个组合。")
            return
        }
        activeShortcut = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: LauncherShortcut.preferenceKey)
        }
    }
    @objc func changeSortFromMenu(_ sender: NSMenuItem) { sort.selectItem(at: sender.tag); sortChanged(); if !panel.isVisible { showPanel() } }
    @objc func showIssues() {
        let view = index.view()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 350)); text.isEditable = false; text.font = .systemFont(ofSize: 12)
        text.string = "搜索范围：\(roots.map(\.path).joined(separator: "；"))\n\n索引与搜索词仅保存在内存。不联网、不读取正文、不修改文档。搜索支持多个空格分隔的文件名关键词。\n\n名称优先：完整名称／无扩展名名称优先，其次开头匹配，最后包含匹配；同级最近修改优先。类型：按扩展名分组，同组最近修改优先。\n\n结果分批显示，每批 100 条，可以继续加载全部匹配项；无匹配数量截断。未下载的云端内部不会主动下载。\n\n访问提示 \(view.errorCount) 处，最多显示 200 处：\n" + view.errors.joined(separator: "\n")
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true; text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        let dialog = NSAlert(); dialog.messageText = "本地索引与访问详情"; dialog.accessoryView = scroll; dialog.runModal()
    }
    @objc func showAbout() { alert("千里眼 2.0", "随时呼出，快速找到本地文件。\n\n\(activeShortcut?.label ?? "菜单栏") 呼出／收起 · esc 收起 · ↑↓ 选择 · ↩ 定位 Finder · ⌘⇧C 复制路径\n\n完全离线、文档只读。仅保存快捷键和外观设置，不保存文件索引、搜索词、目录路径或搜索历史。") }
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
