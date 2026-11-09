import AppKit
import SearchCore

enum LauncherTheme: Int, CaseIterable {
    case dark, light
    static let preferenceKey = "panelAppearance"

    var title: String { self == .dark ? "暗夜模式" : "普通模式" }
    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
    var background: NSColor {
        self == .dark ? NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.135, alpha: 1)
                      : NSColor(srgbRed: 0.978, green: 0.98, blue: 0.992, alpha: 1)
    }
    var border: NSColor { self == .dark ? .white.withAlphaComponent(0.16) : .black.withAlphaComponent(0.12) }
    var brand: NSColor {
        self == .dark ? NSColor(calibratedRed: 0.71, green: 0.66, blue: 1, alpha: 1)
                      : NSColor(srgbRed: 0.35, green: 0.26, blue: 0.73, alpha: 1)
    }
}

final class LauncherDropdown: NSButton {
    private let choices = NSMenu()
    private(set) var indexOfSelectedItem = 0
    var onSelection: (() -> Void)?

    init(label: String, titles: [String]) {
        super.init(frame: .zero)
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        imagePosition = .imageTrailing
        imageHugsTitle = true
        target = self; action = #selector(showChoices)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(label)
        for (index, title) in titles.enumerated() {
            let item = choices.addItem(withTitle: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        selectItem(at: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func selectItem(at index: Int) {
        guard let item = choices.item(at: index) else { return }
        choices.item(at: indexOfSelectedItem)?.state = .off
        indexOfSelectedItem = index
        item.state = .on
        title = item.title
        setAccessibilityValue(title)
    }
    @objc private func showChoices() {
        choices.minimumWidth = max(120, bounds.width)
        let gap: CGFloat = 4
        let below = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + gap : bounds.minY - gap)
        guard let window, let screen = window.screen else {
            choices.popUp(positioning: nil, at: below, in: self)
            return
        }
        choices.update()
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = choices.size
        // Leave room for every choice, including menu padding. If the panel
        // was dragged low, prefer opening above to clipping the last choices.
        let height = max(size.height + 8, CGFloat(choices.numberOfItems) * 26 + 12)
        let belowY = anchor.minY - gap
        let aboveY = anchor.maxY + gap + height
        let y = belowY - height >= available.minY ? belowY : min(aboveY, available.maxY)
        let x = max(available.minX, min(anchor.minX, available.maxX - size.width))
        let point = window.convertPoint(fromScreen: NSPoint(x: x, y: y))
        choices.popUp(positioning: nil, at: convert(point, from: nil), in: self)
    }
    @objc private func choose(_ item: NSMenuItem) {
        selectItem(at: item.tag)
        onSelection?()
    }
}

final class FilterChip: NSButton {
    var onRemove: (() -> Void)?

    init(label: String) {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .recessed
        isBordered = true
        font = .systemFont(ofSize: 10, weight: .medium)
        target = self; action = #selector(removeFilter)
        setAccessibilityLabel(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ value: String?) {
        guard let value, !value.isEmpty else { isHidden = true; title = ""; return }
        title = value + "  ×"
        setAccessibilityValue(value)
        isHidden = false
    }

    @objc private func removeFilter() { onRemove?() }
}

final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() ?? orderOut(nil) }
}

final class ResultRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.23).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 9, yRadius: 9).fill()
    }
}

final class ResultCell: NSTableCellView {
    let glyph = NSImageView()
    let filename = NSTextField(labelWithString: "")
    let location = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let kind = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        glyph.contentTintColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(calibratedRed: 0.67, green: 0.67, blue: 0.89, alpha: 1) : LauncherTheme.light.brand
        }
        filename.font = .systemFont(ofSize: 15, weight: .medium)
        filename.textColor = .labelColor
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        filename.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        kind.font = .systemFont(ofSize: 10, weight: .medium)
        kind.textColor = .tertiaryLabelColor
        kind.alignment = .right
        for view in [glyph, filename, location, detail, kind] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), glyph.centerYAnchor.constraint(equalTo: centerYAnchor), glyph.widthAnchor.constraint(equalToConstant: 30), glyph.heightAnchor.constraint(equalToConstant: 32),
            filename.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 13), filename.topAnchor.constraint(equalTo: topAnchor, constant: 12), filename.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),
            location.leadingAnchor.constraint(equalTo: filename.leadingAnchor), location.topAnchor.constraint(equalTo: filename.bottomAnchor, constant: 5),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17), detail.topAnchor.constraint(equalTo: filename.topAnchor), detail.widthAnchor.constraint(equalToConstant: 115),
            kind.trailingAnchor.constraint(equalTo: detail.trailingAnchor), kind.bottomAnchor.constraint(equalTo: location.bottomAnchor)
        ])
        // Leave the directory visible while the small type label occupies its
        // own trailing area, even with a long path.
        location.trailingAnchor.constraint(equalTo: kind.leadingAnchor, constant: -10).isActive = true
        kind.widthAnchor.constraint(equalToConstant: 50).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ entry: FileEntry, date: String) {
        filename.stringValue = entry.name
        let home = LocalFiles.userHome.path
        let parent = (entry.path as NSString).deletingLastPathComponent
        location.stringValue = parent == home ? "~" : parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
        kind.stringValue = entry.kind == "文件夹" ? "文件夹" : entry.kind.uppercased()
        detail.stringValue = date
        glyph.image = NSImage(systemSymbolName: entry.kind == "文件夹" ? "folder" : "doc.text", accessibilityDescription: entry.kind)
        toolTip = entry.path
        filename.setAccessibilityLabel(entry.name)
        location.setAccessibilityLabel(entry.path)
    }

    func showApplication(_ entry: ApplicationEntry) {
        filename.stringValue = entry.name
        let home = LocalFiles.userHome.path
        let parent = (entry.path as NSString).deletingLastPathComponent
        location.stringValue = parent == home ? "~" : parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
        kind.stringValue = "APP"
        detail.stringValue = "应用"
        glyph.image = NSWorkspace.shared.icon(forFile: entry.path)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        toolTip = entry.path
        filename.setAccessibilityLabel(entry.name)
        location.setAccessibilityLabel(entry.path)
    }
}
