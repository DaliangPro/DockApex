import AppKit
import CoreGraphics

private struct StackEntry: Sendable {
    let url: URL
    let name: String
    let modified: Date
    let directory: Bool
}

@MainActor
final class FileStackController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var panel: NSPanel?
    private var presentation: PopupPresentation?
    private var table: NSTableView?
    private var heading: NSTextField?
    private var footer: NSTextField?
    private var directory: URL?
    private var anchor = CGRect.zero
    private var position = DockPosition.bottom
    private var entries: [StackEntry] = []
    private var generation = 0
    private var presentationGeneration = 0
    private(set) var lastDismissalReason = ""
    private var sortByDate = true
    private var prefersKeyboardSelection = false
    private var monitors: [Any] = []
    private var isOpen = false
    private var visibilityHeld = false
    private var isPresentingMenu = false
    private let onVisibility: (Bool) -> Void
    var isVisible: Bool { isOpen }

    init(onVisibility: @escaping (Bool) -> Void) { self.onVisibility = onVisibility }

    func show(directory: URL, anchor: CGRect, position: DockPosition) {
        if self.directory == directory, isVisible { hide(); return }
        removeMonitors()
        presentationGeneration += 1
        isOpen = true
        self.directory = directory
        self.anchor = anchor
        self.position = position
        prefersKeyboardSelection = NSApp.currentEvent?.type == .keyDown
        if panel == nil { makePanel() }
        guard let panel else { return }
        panel.title = "DockApex · 文件夹：\(FileManager.default.displayName(atPath: directory.path))"
        panel.setAccessibilityTitle(panel.title)
        heading?.stringValue = FileManager.default.displayName(atPath: directory.path)
        entries = []
        table?.deselectAll(nil)
        table?.reloadData()
        footer?.stringValue = "正在读取…"
        fitPanelToContents()
        if !visibilityHeld { visibilityHeld = true; onVisibility(true) }
        presentation?.present()
        panel.makeFirstResponder(table)
        load()
        let presentation = presentationGeneration
        let openedAt = ProcessInfo.processInfo.systemUptime
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.presentationGeneration == presentation else { return false }
                if event.type != .keyDown, event.timestamp > 0, event.timestamp < openedAt { return false }
                if event.type != .keyDown, let point = self.presentation?.canvasClickOutsideContent(event) {
                    // 展开动画还没走完时画布盖着应用栏上的入口：再次点入口照常收起，点别处按点外部收起。
                    self.hide(reason: self.anchor.insetBy(dx: -4, dy: -4).contains(point) ? "anchor-during-open" : "canvas-outside")
                    return true
                }
                if event.window === self.panel { self.presentation?.finishOpeningForInteraction() }
                if event.type == .keyDown, event.keyCode == 53 { self.hide(); return true }
                if event.type != .keyDown, !self.isPresentingMenu, event.window !== self.panel,
                   event.window?.title.hasPrefix("DockApex · 应用栏") != true { self.hide(reason: "local-outside") }
                return false
            }
            return consumed ? nil : event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                guard let self, self.presentationGeneration == presentation, !self.isPresentingMenu,
                      timestamp == 0 || timestamp >= openedAt else { return }
                self.hide(reason: "global-outside")
            }
        }) { monitors.append(global) }
    }

    func hide(reason: String = "explicit", animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        presentationGeneration += 1
        lastDismissalReason = reason
        removeMonitors()
        // 收起一开始就释放应用栏，与分组面板一致。
        if visibilityHeld { visibilityHeld = false; onVisibility(false) }
        presentation?.dismiss(animated: animated) {}
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func makePanel() {
        let panel = StackPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 166), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        // 与分组面板一致：必须高于应用栏和补底，否则面板底部会被盖住。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 3); panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView()
        let heading = NSTextField(labelWithString: "")
        heading.font = .boldSystemFont(ofSize: 14); heading.lineBreakMode = .byTruncatingMiddle
        content.addSubview(heading); self.heading = heading
        let scroll = NSScrollView(); scroll.identifier = NSUserInterfaceItemIdentifier("files-scroll")
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        let table = StackTableView()
        table.onOpen = { [weak self] in self?.openSelected() }
        table.onKeyboardNavigation = { [weak self] in self?.prefersKeyboardSelection = true }
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.headerView = nil; table.rowHeight = 38; table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = CGSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); column.width = 370
        table.addTableColumn(column); table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(openClickedRow(_:))
        table.onContext = { [weak self] row in self?.menu(for: row) ?? NSMenu() }
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        scroll.documentView = table; content.addSubview(scroll); self.table = table
        let footer = NSTextField(labelWithString: "正在读取…"); footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        content.addSubview(footer); self.footer = footer
        let open = NSButton(title: "在 Finder 中打开", target: self, action: #selector(openDirectory)); open.identifier = NSUserInterfaceItemIdentifier("open-folder")
        open.bezelStyle = .inline; content.addSubview(open)
        let sort = NSButton(title: "排序", target: self, action: #selector(toggleSort)); sort.identifier = NSUserInterfaceItemIdentifier("sort-folder")
        sort.bezelStyle = .inline; content.addSubview(sort)
        let surface = PopupSurfaceView(content: content, radius: 22)
        panel.contentView = surface
        self.panel = panel
        presentation = PopupPresentation(panel: panel, surface: surface, kind: "files", onLayout: { [weak self] in self?.layout() })
    }

    /// 读取和排序完成后重新拟合；始终围绕原入口定位，再夹到该屏可见区域。
    private func fitPanelToContents() {
        guard panel != nil else { return }
        let midpoint = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midpoint) }
            ?? NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let filenameFont = NSFont.systemFont(ofSize: 13)
        let longestFilename = entries.reduce(CGFloat.zero) { width, entry in
            max(width, (entry.name as NSString).size(withAttributes: [.font: filenameFont]).width)
        }
        let titleWidth = ((heading?.stringValue ?? "") as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14)]).width
        let desiredWidth = min(420, max(280, ceil(max(longestFilename + 100, titleWidth + 100))))
        // 普通样式移除系统的额外列表内缩；同时以实际最后一行边界兜底，完整容纳所有短列表行。
        var rowsHeight = CGFloat(entries.count) * 40
        if !entries.isEmpty, let table, table.numberOfRows == entries.count {
            rowsHeight = max(rowsHeight, ceil(table.rect(ofRow: entries.count - 1).maxY))
        }
        let desiredHeight = min(560, max(166, 88 + rowsHeight))
        let width = min(desiredWidth, max(1, visible.width - 24))
        let height = min(desiredHeight, max(1, visible.height - 24))
        let desired: CGPoint
        switch position {
        case .bottom: desired = CGPoint(x: anchor.midX - width / 2, y: anchor.maxY + 12)
        case .left: desired = CGPoint(x: anchor.maxX + 12, y: anchor.midY - height / 2)
        case .right: desired = CGPoint(x: anchor.minX - width - 12, y: anchor.midY - height / 2)
        }
        let origin = CGPoint(x: min(max(visible.minX + 12, desired.x), visible.maxX - width - 12),
                             y: min(max(visible.minY + 12, desired.y), visible.maxY - height - 12))
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        presentation?.setLayout(frame: frame, anchor: anchor, position: position)
    }

    private func layout() {
        guard let content = heading?.superview else { return }
        let size = content.bounds.size
        heading?.frame = CGRect(x: 18, y: size.height - 40, width: size.width - 90, height: 24)
        footer?.frame = CGRect(x: 18, y: 12, width: size.width - 165, height: 18)
        content.subviews.first { $0.identifier?.rawValue == "files-scroll" }?.frame = CGRect(x: 12, y: 40, width: size.width - 24, height: size.height - 88)
        content.subviews.first { $0.identifier?.rawValue == "open-folder" }?.frame = CGRect(x: size.width - 155, y: 8, width: 140, height: 26)
        content.subviews.first { $0.identifier?.rawValue == "sort-folder" }?.frame = CGRect(x: size.width - 68, y: size.height - 40, width: 52, height: 24)
        table?.tableColumns.first?.width = size.width - 42
    }

    private func load() {
        guard let directory else { return }
        footer?.stringValue = "正在读取…"
        generation += 1; let token = generation
        Task {
            let result: Result<[StackEntry], Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .localizedNameKey], options: [.skipsHiddenFiles])
                    return urls.map { url in
                        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .localizedNameKey])
                        return StackEntry(url: url, name: values?.localizedName ?? url.lastPathComponent, modified: values?.contentModificationDate ?? .distantPast, directory: values?.isDirectory ?? false)
                    }
                }
            }.value
            guard generation == token else { return }
            switch result {
            case .success(let files):
                // 排序期间保留用户选择的文件，而不是沿用旧行号或强行选中首项。
                let currentSelection = table.flatMap { entries.indices.contains($0.selectedRow) ? entries[$0.selectedRow].url : nil }
                entries = sortByDate ? files.sorted { $0.modified > $1.modified } : files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                entries = Array(entries.prefix(500))
                footer?.stringValue = files.isEmpty ? "文件夹为空" : "\(files.count) 项 · 按\(sortByDate ? "修改时间" : "名称")排序"
                table?.reloadData()
                fitPanelToContents()
                table?.deselectAll(nil)
                if let currentSelection, let row = entries.firstIndex(where: { $0.url == currentSelection }) {
                    table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    table?.scrollRowToVisible(row)
                } else if currentSelection == nil, prefersKeyboardSelection, !entries.isEmpty {
                    table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    table?.scrollRowToVisible(0)
                }
            case .failure(let error):
                footer?.stringValue = "无法读取：\(error.localizedDescription)"
                entries = []; table?.reloadData(); fitPanelToContents()
            }
        }
    }
    @objc private func openClickedRow(_ sender: NSTableView) {
        // NSTableView 的方向键选择也会发送 action；只有真正的鼠标行点击才能单击打开。
        guard let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseUp,
              entries.indices.contains(sender.clickedRow) else { return }
        openEntry(at: sender.clickedRow)
    }
    @objc private func openSelected() {
        guard let row = table?.selectedRow else { return }
        openEntry(at: row)
    }
    private func openEntry(at row: Int) {
        guard entries.indices.contains(row) else { return }
        NSWorkspace.shared.open(entries[row].url); hide()
    }
    @objc private func openDirectory() { if let directory { NSWorkspace.shared.open(directory) }; hide() }
    @objc private func toggleSort() { sortByDate.toggle(); load() }
    private func menu(for row: Int) -> NSMenu {
        guard entries.indices.contains(row) else { return NSMenu() }
        let url = entries[row].url
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(ShelfMenuItem("打开") { [weak self] in NSWorkspace.shared.open(url); self?.hide() })
        menu.addItem(ShelfMenuItem("在 Finder 中显示") { [weak self] in NSWorkspace.shared.activateFileViewerSelecting([url]); self?.hide() })
        menu.addItem(ShelfMenuItem("拷贝") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("移到废纸篓") { [weak self] in
            NSWorkspace.shared.recycle([url]) { [weak self] _, error in
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    if let message { ShelfAppActions.showError(title: "无法移到废纸篓", message: message) }
                    self?.load()
                }
            }
        })
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { isPresentingMenu = true }
    func menuDidClose(_ menu: NSMenu) { isPresentingMenu = false }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        entries.indices.contains(row) ? entries[row].url as NSURL : nil
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView(frame: CGRect(x: 0, y: 0, width: tableColumn?.width ?? tableView.bounds.width, height: tableView.rowHeight))
        let icon = NSImageView(frame: CGRect(x: 4, y: 4, width: 30, height: 30)); icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        let text = NSTextField(labelWithString: entry.name); text.font = .systemFont(ofSize: 13); text.lineBreakMode = .byTruncatingMiddle
        text.frame = CGRect(x: 44, y: 10, width: max(80, cell.bounds.width - 55), height: 20)
        text.autoresizingMask = [.width]
        cell.addSubview(icon); cell.addSubview(text); cell.textField = text; cell.imageView = icon
        cell.setAccessibilityLabel(entry.name)
        return cell
    }
}

@MainActor private final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor private final class StackTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onContext: ((Int) -> NSMenu)?
    var onKeyboardNavigation: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return onContext?(row)
    }
    override func keyDown(with event: NSEvent) {
        let plainNavigation = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plainNavigation, [123, 124, 125, 126, 115, 119].contains(event.keyCode) {
            onKeyboardNavigation?()
            if selectedRow < 0, numberOfRows > 0, [125, 126, 115, 119].contains(event.keyCode) {
                let row = event.keyCode == 119 || event.keyCode == 126 ? numberOfRows - 1 : 0
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                scrollRowToVisible(row)
                return
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 { onOpen?() } else { super.keyDown(with: event) }
    }
}
