import AppKit

/// 应用栏与分组面板里图标的右键菜单。系统菜单窗口加不了指向图标的箭头，改用系统弹出框承载：
/// 箭头与外框是同一块材质，和原生 Dock 菜单一样指向图标。菜单项仍由 NSMenu 构建（标题、分隔线、勾选、
/// 小图、可用状态与动作），这里只负责显示、点选、按住拖到项上松开、键盘与关闭。
@MainActor
final class DockMenuPopover: NSObject, NSPopoverDelegate {
    static let shared = DockMenuPopover()

    private var popover: NSPopover?
    private var menu: NSMenu?
    private var list: DockMenuListView?
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?
    /// 由按下（右键或长按）打开、按键还没松开：此时拖到项上松开即选中。
    private var pressActive = false
    /// 打开前在前台的 App；点选弹出框若让本应用变成活跃，关闭后交还。
    private var previousApp: NSRunningApplication?

    var isShown: Bool { popover?.isShown == true }

    /// 指针是否在弹出框上（含箭头）；分组面板等的“点外面收起”据此放过。
    func contains(screenPoint: CGPoint) -> Bool { list?.window?.frame.contains(screenPoint) == true }

    func show(_ menu: NSMenu, from view: NSView, rect: NSRect, edge: NSRectEdge, byPress: Bool, keyboard: Bool,
              onClose: (() -> Void)? = nil) {
        close()
        self.menu = menu
        self.onClose = onClose
        pressActive = byPress
        previousApp = NSWorkspace.shared.frontmostApplication
        let list = DockMenuListView(menu: menu) { [weak self] index in self?.activate(index) }
        self.list = list
        (menu as? ShelfApplicationMenu)?.onItemsChanged = { [weak self] in self?.reload() }
        let controller = NSViewController()
        controller.view = list
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = list.fittingSize
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        if let window = list.window {
            // 与系统菜单一样点选时不激活本应用、不抢走当前 App 的键盘焦点。
            if let panel = window as? NSPanel { panel.styleMask.insert(.nonactivatingPanel); panel.becomesKeyOnlyIfNeeded = !keyboard }
            if keyboard { window.makeKey(); window.makeFirstResponder(list); list.highlightFirst() }
        }
        installMonitors()
    }

    func close() {
        guard let popover else { return }
        self.popover = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        (menu as? ShelfApplicationMenu)?.onItemsChanged = nil
        popover.close()
        list = nil; pressActive = false
        let closed = onClose
        onClose = nil
        if NSApp.isActive, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
        closed?()
    }

    /// 按住拖动时跟随高亮；返回是否由弹出框处理。
    @discardableResult
    func trackPress(at screenPoint: CGPoint) -> Bool {
        guard pressActive, let list else { return false }
        list.highlight(atScreenPoint: screenPoint)
        return true
    }

    /// 按住后松开：落在可用项上就选中，否则保持打开。返回是否由弹出框处理。
    @discardableResult
    func releasePress(at screenPoint: CGPoint) -> Bool {
        guard pressActive, let list else { return false }
        pressActive = false
        if let index = list.index(atScreenPoint: screenPoint) { activate(index) }
        return true
    }

    private func activate(_ index: Int) {
        guard let menu, menu.items.indices.contains(index), menu.items[index].isEnabled, !menu.items[index].isSeparatorItem else { return }
        close()
        menu.performActionForItem(at: index)
    }

    private func reload() {
        guard let list, let popover else { return }
        list.reload()
        popover.contentSize = list.fittingSize
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let list = self.list else { return false }
                if event.type == .keyDown { return list.handleKey(event) }
                if event.window !== list.window { self.close() }
                return false
            }
            return consumed ? nil : event
        }) { monitors.append(local) }
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as AnyObject?) === popover { close() }
    }
}

/// 菜单项列表：行高、分隔、勾选列与高亮按系统菜单的样子画。
@MainActor
private final class DockMenuListView: NSView {
    private static let rowHeight: CGFloat = 22
    private static let separatorHeight: CGFloat = 11
    private static let padding: CGFloat = 5
    private static let textX: CGFloat = 26
    private static let rightPadding: CGFloat = 18
    private let source: NSMenu
    private let onActivate: (Int) -> Void
    private var rows: [(index: Int, frame: CGRect)] = []
    private var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    private var width: CGFloat = 140
    private let font = NSFont.menuFont(ofSize: 0)

    init(menu: NSMenu, onActivate: @escaping (Int) -> Void) {
        self.source = menu
        self.onActivate = onActivate
        super.init(frame: .zero)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("不支持从归档载入菜单") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var fittingSize: NSSize { NSSize(width: width, height: (rows.last?.frame.maxY ?? 0) + Self.padding) }

    func reload() {
        var y = Self.padding, widest: CGFloat = 0
        rows = []
        for (index, item) in source.items.enumerated() where !item.isHidden {
            let height = item.isSeparatorItem ? Self.separatorHeight : Self.rowHeight
            rows.append((index, CGRect(x: 0, y: y, width: 0, height: height)))
            y += height
            if !item.isSeparatorItem { widest = max(widest, (item.title as NSString).size(withAttributes: [.font: font]).width) }
        }
        width = min(420, max(140, ceil(Self.textX + widest + Self.rightPadding)))
        rows = rows.map { ($0.index, CGRect(x: 0, y: $0.frame.minY, width: width, height: $0.frame.height)) }
        setFrameSize(fittingSize)
        if let highlighted, !rows.contains(where: { $0.index == highlighted }) { self.highlighted = nil }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with event: NSEvent) { highlighted = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { highlighted = nil }
    override func mouseDown(with event: NSEvent) { highlighted = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) { onActivate(index) }
    }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    func highlight(atScreenPoint point: CGPoint) {
        guard let window else { return }
        highlighted = index(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }
    func index(atScreenPoint point: CGPoint) -> Int? {
        guard let window, window.frame.contains(point) else { return nil }
        return index(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }
    func highlightFirst() { highlighted = selectable.first }

    /// 上下移动、回车选中、Esc 关闭；返回是否处理。
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 126:
            let options = selectable
            guard !options.isEmpty else { return true }
            let current = highlighted.flatMap { options.firstIndex(of: $0) }
            let next = event.keyCode == 125 ? (current.map { min($0 + 1, options.count - 1) } ?? 0)
                                            : (current.map { max($0 - 1, 0) } ?? options.count - 1)
            highlighted = options[next]
        case 36, 76: if let highlighted { onActivate(highlighted) }
        case 53: DockMenuPopover.shared.close()
        default: return false
        }
        return true
    }

    private var selectable: [Int] {
        rows.map(\.index).filter { source.items[$0].isEnabled && !source.items[$0].isSeparatorItem }
    }

    private func index(at point: CGPoint) -> Int? {
        guard let row = rows.first(where: { $0.frame.contains(point) }) else { return nil }
        let item = source.items[row.index]
        return item.isEnabled && !item.isSeparatorItem ? row.index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for row in rows {
            let item = source.items[row.index]
            if item.isSeparatorItem {
                NSColor.separatorColor.setFill()
                CGRect(x: 12, y: row.frame.midY - 0.5, width: width - 24, height: 1).fill()
                continue
            }
            let selected = row.index == highlighted && item.isEnabled
            if selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: row.frame.insetBy(dx: 5, dy: 0), xRadius: 6, yRadius: 6).fill()
            }
            let color: NSColor = !item.isEnabled ? .tertiaryLabelColor : (selected ? .white : .labelColor)
            if let image = item.image {
                let size = image.size
                let rect = CGRect(x: 15 - size.width / 2, y: row.frame.midY - size.height / 2, width: size.width, height: size.height)
                let tinted = image.copy() as? NSImage ?? image
                tinted.isTemplate = true
                color.set()
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if item.state == .on, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已选")?
                        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                let size = check.size
                let rect = CGRect(x: 15 - size.width / 2, y: row.frame.midY - size.height / 2, width: size.width, height: size.height)
                let tinted = NSImage(size: size, flipped: false) { bounds in
                    check.draw(in: bounds); color.set(); bounds.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let title = item.title as NSString
            let textHeight = title.size(withAttributes: attributes).height
            let textRect = CGRect(x: Self.textX, y: row.frame.midY - textHeight / 2,
                                  width: width - Self.textX - Self.rightPadding + 4, height: textHeight)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
            title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                       attributes: attributes.merging([.paragraphStyle: style]) { $1 })
        }
    }
}
