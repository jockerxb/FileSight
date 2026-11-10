import AppKit
import SearchCore

enum LauncherResult {
    case application(ApplicationEntry)
    case file(FileEntry)

    var path: String {
        switch self {
        case .application(let entry): entry.path
        case .file(let entry): entry.path
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSWindowDelegate {
    let database: IndexDatabase?
    let databaseError: String?
    let index: FileIndex
    let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 210), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let field = NSTextField()
    let scope = LauncherDropdown(label: "搜索范围", titles: Scope.allCases.map(\.title))
    let sort = LauncherDropdown(label: "排序方式", titles: AppDelegate.orderTitles)
    let logo = NSImageView(image: Branding.mark())
    let direction = NSButton()
    let status = NSTextField(labelWithString: "")
    let authorize = NSButton()
    let typeChip = FilterChip(label: "文件类型筛选")
    let dateChip = FilterChip(label: "日期筛选")
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
        var title: String { self == .downloads ? "文件：下载" : "文件：选择目录…" }
    }
    let downloads = LocalFiles.userHome.appendingPathComponent("Downloads", isDirectory: true)
    var selectedScope: Scope = .downloads
    var roots: [ScanRoot] = []
    var activeDirectoryAccess: [URL] = []
    var rows: [LauncherResult] = []
    var applications: [ApplicationEntry] = []
    var visibleApplications: [ApplicationEntry] = []
    var applicationRevision = 0
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
    var pollInFlight = false
    var appliedKey = ""
    var shownRevision = -1
    var lastAutomatic = Date.distantPast
    var lastPanelPresentationMilliseconds: Double = 0
    var lastDatabaseSearchMilliseconds: Double = 0
    var lastDatabaseCountMilliseconds: Double = 0
    var panelTransition = 0
    var panelRequestedVisible = false
    var hotkeyEventCount = 0
    var hotkeyShowCount = 0
    var hotkeyHideCount = 0
    let searchQueue = DispatchQueue(label: "qianliyan.quick-search", qos: .userInitiated)
    let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy/MM/dd HH:mm"; return f
    }()
    var productTitle: String { "千里眼 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.3")" }
    static let orderTitles = ["名称优先", "修改时间", "创建时间", "文件类型", "文件名"]
    var theme = LauncherTheme(rawValue: UserDefaults.standard.integer(forKey: LauncherTheme.preferenceKey)) ?? .dark

    override init() {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
                .appendingPathComponent("FileSight", isDirectory: true)
            let loaded = try IndexDatabase.openRecovering(url: base.appendingPathComponent("metadata.sqlite3"))
            database = loaded; databaseError = nil; index = FileIndex(database: loaded)
        } catch {
            database = nil; databaseError = error.localizedDescription; index = FileIndex()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        restoreDirectoryAuthorization()
        buildApplicationMenu()
        buildPanel()
        buildStatusItem()
        hotkey.action = { [weak self] eventTime in
            guard let self, !self.editingShortcut else { return }
            self.togglePanelFromHotKey(eventTime: eventTime)
        }
        let saved = UserDefaults.standard.data(forKey: LauncherShortcut.preferenceKey)
            .flatMap { try? JSONDecoder().decode(LauncherShortcut.self, from: $0) }
        let preferred = saved.flatMap { $0.isValid ? $0 : nil } ?? .defaultShortcut
        if hotkey.register(preferred) { activeShortcut = preferred }
        loadApplications()
        if !LoginLaunch.isLoginEvent { showPanel() }
        startIndex(forceRebuild: false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in self?.pollIndex() }
    }

    func restoreDirectoryAuthorization() {
        let restored = DirectoryAuthorizationStore.restore()
        do {
            try replaceDirectoryRoots(restored)
        } catch {
            DirectoryAuthorizationStore.clear()
            try? database?.clearAll()
            roots = []
        }
        let downloadsPath = FileIndex.canonicalRoot(downloads).path
        selectedScope = roots.count == 1 && roots[0].path == downloadsPath ? .downloads : roots.isEmpty ? .downloads : .custom
    }

    func replaceDirectoryRoots(_ nextRoots: [ScanRoot]) throws {
        var nextAccess: [URL] = []
        do {
            for root in nextRoots { nextAccess.append(try root.startAccessing()) }
        } catch {
            nextAccess.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
        index.stop()
        activeDirectoryAccess.forEach { $0.stopAccessingSecurityScopedResource() }
        activeDirectoryAccess = nextAccess
        roots = nextRoots
    }

    func applicationWillTerminate(_ notification: Notification) {
        index.stop()
        activeDirectoryAccess.forEach { $0.stopAccessingSecurityScopedResource() }
        activeDirectoryAccess = []
    }

    func applicationDidResignActive(_ notification: Notification) {
        // AppKit hides a panel asynchronously. Keep visibility under one state
        // machine so the next hotkey cannot observe a stale visible state.
        if panelRequestedVisible { dismissPanel() }
    }

    func loadApplications() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = ApplicationCatalog.load()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applications = found
                self.applicationRevision += 1
                if !self.field.stringValue.isEmpty { self.requestSearch(resetLimit: true) }
            }
        }
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
        panel.onCancel = { [weak self] in self?.dismissPanel() }
        panel.isFloatingPanel = true; panel.level = .floating
        // Automatic hiding would create a second, asynchronous source of truth.
        panel.hidesOnDeactivate = false
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
        field.placeholderAttributedString = NSAttributedString(string: "搜索 App 或本地文件…", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 27, weight: .regular)])
        field.delegate = self; field.setAccessibilityLabel("搜索 App 或文件名")
        for view in [logo, field] { top.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 24), logo.centerYAnchor.constraint(equalTo: top.centerYAnchor), logo.widthAnchor.constraint(equalToConstant: 34), logo.heightAnchor.constraint(equalTo: logo.widthAnchor),
            field.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 13), field.centerYAnchor.constraint(equalTo: top.centerYAnchor, constant: 3), field.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -24), field.heightAnchor.constraint(equalToConstant: 40)
        ])
        top.heightAnchor.constraint(equalToConstant: 72).isActive = true
        scope.onSelection = { [weak self] in self?.scopeChanged() }
        scope.selectItem(at: selectedScope.rawValue)
        scope.toolTip = roots.map(\.path).joined(separator: "；")
        sort.onSelection = { [weak self] in self?.sortChanged() }
        configure(direction, title: "", action: #selector(toggleDirection))
        updateDirection()
        configure(authorize, title: "授权下载…", action: #selector(authorizeDownloads))
        typeChip.onRemove = { [weak self] in self?.removeTypeFilter() }
        dateChip.onRemove = { [weak self] in self?.removeDateFilter() }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.isHidden = true
        let controls = NSStackView(views: [scope, authorize, typeChip, dateChip, status, NSView(), sort, direction])
        controls.spacing = 8; controls.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 20)
        controls.heightAnchor.constraint(equalToConstant: 35).isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); table.addTableColumn(column)
        table.style = .plain
        table.headerView = nil; table.rowHeight = 66; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular; table.focusRingType = .none
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(performSelected)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let actions = NSMenu()
        actions.addItem(withTitle: "打开", action: #selector(performSelected), keyEquivalent: "").target = self
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

    @objc func showPanel() { presentPanel(eventTime: nil) }
    func presentPanel(eventTime: TimeInterval?) {
        let started = ProcessInfo.processInfo.systemUptime
        panelRequestedVisible = true
        panelTransition &+= 1
        let transition = panelTransition
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let height = desiredPanelHeight
        let frame = NSRect(x: area.midX - 390, y: area.maxY - height - max(65, area.height * 0.14),
                           width: 780, height: min(height, area.height - 100))
        // Do not synchronously redraw the retained result table on the hotkey
        // event. Put the panel on screen first and let AppKit composite it on
        // the next frame while activation completes.
        // Activate first: a non-activating panel made key before activation can
        // immediately resign again while AppKit completes the app transition.
        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        let finished = ProcessInfo.processInfo.systemUptime
        let origin = eventTime.flatMap { $0 <= finished && finished - $0 < 10 ? $0 : nil } ?? started
        lastPanelPresentationMilliseconds = (finished - origin) * 1000
        panel.contentView?.needsLayout = true
        panel.contentView?.needsDisplay = true
        panel.viewsNeedDisplay = true
        // Commit dirty layers on the next run-loop turn, after the hotkey
        // event has returned. A newer show/hide transition invalidates this
        // work so an old frame cannot overwrite the current window state.
        DispatchQueue.main.async { [weak self] in
            guard let self, transition == self.panelTransition, self.panelRequestedVisible, self.panel.isVisible else { return }
            self.panel.contentView?.layoutSubtreeIfNeeded()
            self.panel.displayIfNeeded()
            self.panel.makeFirstResponder(self.field)
        }
        // The hotkey path must only paint and focus the already-built panel.
        // Index snapshots are prepared off the main thread after the first frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, transition == self.panelTransition, self.panelRequestedVisible, self.panel.isVisible else { return }
            self.pollIndex()
        }
    }
    func dismissPanel() {
        panelRequestedVisible = false
        panelTransition &+= 1
        panel.orderOut(nil)
    }
    @objc func togglePanel() { panelRequestedVisible ? dismissPanel() : presentPanel(eventTime: nil) }
    func togglePanelFromHotKey(eventTime: TimeInterval) {
        hotkeyEventCount += 1
        if panelRequestedVisible {
            hotkeyHideCount += 1
            dismissPanel()
        } else {
            hotkeyShowCount += 1
            presentPanel(eventTime: eventTime)
        }
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true { showStatusMenu() }
        else { togglePanel() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismissPanel(); return false }
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panelRequestedVisible else { return }
        // A non-activating panel can lose key status without the application
        // resigning active. Close synchronously; never infer state from the
        // asynchronously updated NSWindow.isVisible property.
        dismissPanel()
    }
    func controlTextDidChange(_ obj: Notification) {
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        requestSearch(resetLimit: true)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): dismissPanel(); return true
        case #selector(NSResponder.moveDown(_:)): selectOffset(1); return true
        case #selector(NSResponder.moveUp(_:)): selectOffset(-1); return true
        case #selector(NSResponder.insertNewline(_:)): performSelected(); return true
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
            rows = []; visibleApplications = []; totalMatches = 0; table.reloadData(); appliedKey = ""
            typeChip.show(nil); dateChip.show(nil)
            updateSearchDisplay(message: "")
            return
        }
        let parsed = ParsedSearchQuery.parse(trimmed)
        updateFilterChips(parsed)
        visibleApplications = ApplicationCatalog.search(applications, query: parsed.text)
        rows = visibleApplications.map(LauncherResult.application)
        totalMatches = 0
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if roots.isEmpty {
            updateSearchDisplay(message: visibleApplications.isEmpty ? "未找到应用 · 文件目录未授权" : "\(visibleApplications.count) 个应用")
            return
        }
        let initial = visibleApplications.isEmpty ? "正在查找文件…" : "\(visibleApplications.count) 个应用 · 正在查找文件…"
        updateSearchDisplay(message: initial, loading: true)
        let work = DispatchWorkItem { [weak self] in self?.performSearch() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }
    var desiredPanelHeight: CGFloat {
        // Search bar, controls, and their separator.
        let chrome: CGFloat = 72 + 35 + 1
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
    func searchKey(_ view: IndexView) -> String {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return "\(scanGeneration)|\(view.revision)|\(applicationRevision)|\(day)|\(field.stringValue)|\(order.rawValue)|\(ascending)|\(limit)"
    }
    func performSearch(view providedView: IndexView? = nil) {
        guard !searchBusy else { return }
        let query = field.stringValue
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !roots.isEmpty else { return }
        let id = requestID, generation = scanGeneration, appRevision = applicationRevision,
            parsed = ParsedSearchQuery.parse(query), sortOrder = order, asc = ascending,
            pageLimit = limit, cancellation = token, appRows = visibleApplications,
            day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970,
            previousKey = appliedKey
        searchBusy = true
        searchQueue.async { [weak self] in
            guard let self else { return }
            let view = providedView ?? self.index.view()
            let key = "\(generation)|\(view.revision)|\(appRevision)|\(day)|\(query)|\(sortOrder.rawValue)|\(asc)|\(pageLimit)"
            if key == previousKey {
                DispatchQueue.main.async { [weak self] in
                    guard let self, id == self.requestID else { return }
                    self.searchBusy = false
                }
                return
            }
            if let database = self.database {
                do {
                    let page = try database.search(parsed: parsed, order: sortOrder, ascending: asc,
                                                   limit: pageLimit, cancellation: cancellation)
                    guard !cancellation.cancelled, let page else { return }
                    DispatchQueue.main.async {
                        self.applyDatabasePage(page, applications: appRows, request: id, generation: generation,
                                               scanning: view.scanning, key: key)
                    }
                    let countStarted = ProcessInfo.processInfo.systemUptime
                    let total = try database.count(parsed: parsed, cancellation: cancellation)
                    let countMilliseconds = (ProcessInfo.processInfo.systemUptime - countStarted) * 1000
                    guard !cancellation.cancelled, let total else { return }
                    DispatchQueue.main.async {
                        self.applyDatabaseCount(total, applications: appRows, request: id,
                                                generation: generation, scanning: view.scanning,
                                                milliseconds: countMilliseconds)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard id == self.requestID, generation == self.scanGeneration else { return }
                        self.searchBusy = false
                        self.updateSearchDisplay(message: "本地索引暂时不可用")
                    }
                }
                return
            }
            let output = QuickSearch.search(pages: view.pages, parsed: parsed, order: sortOrder, ascending: asc,
                                            limit: pageLimit, cancellation: cancellation, timeLimit: 1.8) { [weak self] partial in
                DispatchQueue.main.async {
                    self?.applyFileSearch(partial, applications: appRows, request: id,
                                          generation: generation, scanning: view.scanning, final: false, key: key)
                }
            }
            DispatchQueue.main.async {
                guard id == self.requestID, generation == self.scanGeneration else { return }
                self.searchBusy = false
                guard !cancellation.cancelled, let output else {
                    if !cancellation.cancelled { self.updateSearchDisplay(message: "搜索已停止，请继续输入") }
                    return
                }
                self.applyFileSearch(output, applications: appRows, request: id,
                                     generation: generation, scanning: view.scanning, final: true, key: key)
            }
        }
    }

    func applyDatabasePage(_ output: DatabaseSearchResult, applications appRows: [ApplicationEntry], request id: Int,
                           generation: Int, scanning: Bool, key: String) {
        guard id == requestID, generation == scanGeneration, !token.cancelled else { return }
        searchBusy = false
        lastDatabaseSearchMilliseconds = output.milliseconds
        let selected = selectedResult?.path
        rows = appRows.map(LauncherResult.application) + output.rows.map(LauncherResult.file)
        totalMatches = output.rows.count + (output.hasMore ? 1 : 0)
        table.reloadData()
        let selection = selected.flatMap { path in rows.firstIndex(where: { $0.path == path }) } ?? 0
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        let appText = appRows.isEmpty ? "" : "\(appRows.count) 个应用"
        let separator = appText.isEmpty ? "" : " · "
        let message: String
        if output.rows.isEmpty {
            message = appRows.isEmpty ? (scanning ? "索引更新中…" : "没有匹配项") : appText
        } else {
            message = appText + separator + "已显示 \(output.rows.count) 个文件 · 正在统计…"
        }
        appliedKey = key
        updateSearchDisplay(message: message)
    }

    func applyDatabaseCount(_ total: Int, applications appRows: [ApplicationEntry], request id: Int,
                            generation: Int, scanning: Bool, milliseconds: Double) {
        guard id == requestID, generation == scanGeneration, !token.cancelled else { return }
        lastDatabaseCountMilliseconds = milliseconds
        totalMatches = total
        let appText = appRows.isEmpty ? "" : "\(appRows.count) 个应用"
        let separator = appText.isEmpty ? "" : " · "
        let message: String
        if total > 0 { message = appText + separator + "\(total.formatted()) 个文件" + (scanning ? " · 索引更新中" : "") }
        else if !appRows.isEmpty { message = appText + (scanning ? " · 索引更新中" : "") }
        else { message = scanning ? "索引更新中…" : "没有匹配项" }
        updateSearchDisplay(message: message)
    }

    func applyFileSearch(_ output: QuickSearchResult, applications appRows: [ApplicationEntry], request id: Int,
                         generation: Int, scanning: Bool, final: Bool, key: String) {
        guard id == requestID, generation == scanGeneration, !token.cancelled else { return }
        let selected = selectedResult?.path
        rows = appRows.map(LauncherResult.application) + output.rows.map(LauncherResult.file)
        totalMatches = output.total
        table.reloadData()
        let selection = selected.flatMap { path in rows.firstIndex(where: { $0.path == path }) } ?? 0
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        let appText = appRows.isEmpty ? "" : "\(appRows.count) 个应用"
        let separator = appText.isEmpty ? "" : " · "
        let message: String
        if !final {
            message = appText + separator + (output.rows.isEmpty ? "继续查找文件…" : "已找到 \(output.rows.count) 个文件 · 继续查找…")
        } else if !output.isComplete {
            message = appText + separator + (output.rows.isEmpty ? "结果范围较大，请继续输入" : "已显示 \(output.rows.count) 个文件 · 请继续输入")
        } else if output.total > 0 {
            message = appText + separator + "\(output.total.formatted()) 个文件" + (scanning ? " · 索引更新中" : "")
        } else if !appRows.isEmpty {
            message = appText + (scanning ? " · 索引更新中" : "")
        } else {
            message = scanning ? "索引更新中…" : "没有匹配项"
        }
        if final { appliedKey = key }
        updateSearchDisplay(message: message, loading: !final || !output.isComplete)
    }
    func updateSearchDisplay(message: String, loading: Bool = false) {
        summary.stringValue = message
        body.isHidden = rows.isEmpty
        countRow.isHidden = message.isEmpty
        let shownFiles = rows.reduce(into: 0) { if case .file = $1 { $0 += 1 } }
        more.isHidden = shownFiles >= totalMatches || loading
        resizePanel()
    }

    func updateFilterChips(_ parsed: ParsedSearchQuery) {
        typeChip.show(parsed.categories.isEmpty ? nil : parsed.categoryTitle)
        dateChip.show(parsed.date?.title)
    }

    func removeTypeFilter() {
        let parsed = ParsedSearchQuery.parse(field.stringValue)
        field.stringValue = parsed.withoutCategories
        requestSearch(resetLimit: true)
    }

    func removeDateFilter() {
        let parsed = ParsedSearchQuery.parse(field.stringValue)
        field.stringValue = parsed.withoutDate
        requestSearch(resetLimit: true)
    }
    func pollIndex() {
        guard panel.isVisible || settings?.window?.isVisible == true, !pollInFlight else { return }
        pollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let view = self.index.view()
            DispatchQueue.main.async {
                self.pollInFlight = false
                if self.shownRevision != view.revision {
                    self.shownRevision = view.revision
                    self.status.stringValue = view.scanning ? (view.rebuilding ? "建立本地索引…" : "同步文件变化…")
                        : view.errorCount > 0 ? "部分目录未读取" : ""
                    self.status.isHidden = self.status.stringValue.isEmpty
                }
                guard self.panel.isVisible, !self.roots.isEmpty, !self.searchBusy, !self.field.stringValue.isEmpty,
                      self.searchKey(view) != self.appliedKey,
                      Date().timeIntervalSince(self.lastAutomatic) >= 1.2 else { return }
                self.lastAutomatic = Date()
                self.performSearch(view: view)
            }
        }
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
        dialog.message = "只读搜索你选中的本地目录。授权与文件元数据索引仅保存在本机沙盒。"
        if dialog.runModal() == .OK {
            do {
                let selected = try dialog.urls.map(ScanRoot.authorized)
                selectedScope = requested == .downloads && selected.count == 1 && selected[0].path == FileIndex.canonicalRoot(downloads).path
                    ? .downloads : .custom
                try replaceDirectoryRoots(selected)
                DirectoryAuthorizationStore.save(roots)
                rescan()
            } catch {
                alert("无法授权目录", "请选择可读取的本地文件夹；未更改原有搜索范围。")
            }
        }
        scope.selectItem(at: selectedScope.rawValue)
        presentPanel(eventTime: nil)
    }
    func startIndex(forceRebuild: Bool) {
        requestID += 1; scanGeneration += 1; token.cancel(); token = SearchCancellation(); pending?.cancel(); searchBusy = false; appliedKey = ""; shownRevision = -1
        index.start(authorizedRoots: roots, forceRebuild: forceRebuild)
        authorize.isHidden = !roots.isEmpty
        scope.toolTip = roots.isEmpty ? "尚未授权目录" : roots.map(\.path).joined(separator: "；")
        rows = []; table.reloadData()
        if !field.stringValue.isEmpty { requestSearch(resetLimit: true) }
        pollIndex()
    }
    @objc func rescan() { startIndex(forceRebuild: true) }
    var selectedResult: LauncherResult? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    @objc func performSelected() {
        guard let selectedResult else { return }
        switch selectedResult {
        case .application(let entry):
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: entry.path), configuration: configuration)
        case .file(let entry):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
        dismissPanel()
    }
    @objc func copyPath() {
        guard let selectedResult else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedResult.path, forType: .string)
        summary.stringValue = "已复制路径"
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
        if case .application = selectedResult { menu.item(at: 0)?.title = "打开应用" }
        else { menu.item(at: 0)?.title = "在 Finder 中显示" }
    }
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
            controller.onClearDirectoryAuthorization = { [weak self] in self?.confirmClearDirectoryAuthorization() }
            settings = controller
        }
        dismissPanel()
        settings?.update(theme: theme, shortcut: activeShortcut, hasDirectoryAuthorization: !roots.isEmpty)
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
    func confirmClearDirectoryAuthorization() {
        guard let window = settings?.window, !roots.isEmpty else { return }
        let dialog = NSAlert()
        dialog.messageText = "取消目录授权？"
        dialog.informativeText = "将停止文件搜索并清除已保存的目录凭证。App 搜索不受影响。"
        dialog.addButton(withTitle: "取消授权")
        dialog.addButton(withTitle: "保留")
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            DirectoryAuthorizationStore.clear()
            try? self.database?.clearAll()
            try? self.replaceDirectoryRoots([])
            self.selectedScope = .downloads
            self.scope.selectItem(at: self.selectedScope.rawValue)
            self.startIndex(forceRebuild: false)
            self.settings?.update(theme: self.theme, shortcut: self.activeShortcut, hasDirectoryAuthorization: false)
        }
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
        let panelLatency = lastPanelPresentationMilliseconds > 0
            ? " · 窗口准备 \(Int(lastPanelPresentationMilliseconds.rounded())) ms" : ""
        let hotkeyState = " · 快捷键 \(hotkeyEventCount) 次（显示 \(hotkeyShowCount) / 收起 \(hotkeyHideCount)）"
        let storageState = database.map { " · SQLite \(ByteCountFormatter.string(fromByteCount: $0.storageBytes, countStyle: .file))" }
            ?? " · 内存降级"
        let queryTiming = lastDatabaseSearchMilliseconds > 0
            ? " · 结果 \(Int(lastDatabaseSearchMilliseconds.rounded())) ms / 总数 \(Int(lastDatabaseCountMilliseconds.rounded())) ms" : ""
        if roots.isEmpty {
            dialog.informativeText = "尚未授权目录。请先从搜索面板选择目录。" + storageState + panelLatency + hotkeyState
        } else {
            let state = view.scanning ? (view.rebuilding ? "正在建库" : "正在同步") : view.errorCount > 0 ? "有访问提示" : "索引已就绪"
            dialog.informativeText = "\(state) · 已收录 \(view.count.formatted()) 项" + storageState + queryTiming + panelLatency + hotkeyState
        }
        dialog.addButton(withTitle: "完成")
        let canRefresh = !roots.isEmpty && !view.scanning
        if canRefresh { dialog.addButton(withTitle: "刷新索引") }
        if !roots.isEmpty {
            let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 395, height: 125))
            details.isEditable = false; details.font = .systemFont(ofSize: 12)
            let issues = view.errorCount > 0 ? "\n\n访问提示（\(view.errorCount) 处）\n" + view.errors.joined(separator: "\n") : ""
            let storageIssue = databaseError.map { "\n\nSQLite 已降级\n\($0)" } ?? ""
            details.string = "搜索范围\n" + roots.map(\.path).joined(separator: "\n") + issues + storageIssue
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
        switch rows[row] {
        case .application(let entry):
            cell.showApplication(entry)
        case .file(let entry):
            let date = order == .created ? entry.created : entry.modified
            cell.show(entry, date: date == .distantPast ? "时间未知" : formatter.string(from: date))
        }
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
