import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuartzCore

/// 分组与应用栏共享应用操作；面板锚定实际图标边界。
@MainActor
final class GroupPanelController {
    private var panel: GroupPopoverPanel?
    private var presentation: PopupPresentation?
    private var content: GroupGridView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var runtimeObservers: [NSObjectProtocol] = []
    private let onChanged: (AppGroup) -> Void
    private let onVisibility: (Bool) -> Void
    private var anchor = CGRect.zero
    private var position = DockPosition.bottom
    private var previousApplication: NSRunningApplication?
    private var generation = 0
    private var badges: [String: String] = [:]
    private var pendingAnchor: CGRect?
    private var isOpen = false
    private var visibilityHeld = false
    private var presentedAt: TimeInterval = 0
    private var pendingExternalDismissal = false
    private(set) var lastDismissalReason = ""
    /// 与应用栏共用“启动时跳动”设置。
    var animatesLaunch = true { didSet { content?.animatesLaunch = animatesLaunch } }
    var currentGroupID: UUID? { isOpen ? content?.group.id : nil }
    /// 展开时面板的屏幕位置；应用栏拖动时据此判断是否拖进了分组。
    var presentedFrame: CGRect? { isOpen ? panel?.frame : nil }
    /// 窗口预览出现时收起成员名称提示。
    func hideMemberNameHint() { content?.hideNameHint() }
    /// 拖动关键步骤的耗时记录（写入活动日志），用于核对拖出分组的首帧卡顿。
    static var log: ((String) -> Void)?
    /// 成员拖出面板后交给应用栏预览（nil 表示回到面板内）；松开时由应用栏决定是否接收。由应用控制器设置。
    static var referenceDragMoved: ((CGPoint?) -> Void)?
    static var referenceDropped: ((URL, CGPoint) -> Bool)?

    /// 应用栏上的应用拖到展开的面板上：按指针位置让出空位，需要时面板平滑加行；nil 表示离开面板。
    func previewIncoming(at screenPoint: CGPoint?) {
        guard isOpen, let content else { return }
        if content.updateIncoming(at: screenPoint) { layoutPanel(resizeAnimated: true) }
    }

    /// 让出的空位（屏幕坐标），拖动图标飞进这里。
    func incomingLandingRect() -> CGRect? { isOpen ? content?.incomingLandingRect() : nil }

    /// 取走空位位置；随后加入的成员就插在这里。
    func takeIncomingIndex() -> Int? { content?.takeIncomingGap() }

    init(onChanged: @escaping (AppGroup) -> Void, onVisibility: @escaping (Bool) -> Void = { _ in }) {
        self.onChanged = onChanged
        self.onVisibility = onVisibility
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            runtimeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let path = application?.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
                let activatedPID = name == NSWorkspace.didActivateApplicationNotification ? application?.processIdentifier : nil
                let regular = application?.activationPolicy == .regular
                let invalidatesIcon = name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didTerminateApplicationNotification
                let occurredAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if invalidatesIcon, let path { DockIconProvider.shared.invalidate(appPath: path) }
                    content?.refreshRuntime()
                    if isOpen, occurredAt >= presentedAt, regular, let activatedPID,
                       activatedPID != ProcessInfo.processInfo.processIdentifier {
                        pendingExternalDismissal = true
                        dismissAfterExternalActivationIfReady()
                    }
                }
            })
        }
    }

    func show(group: AppGroup, near point: CGPoint, position: DockPosition = .bottom) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        show(group: group, anchor: CGRect(x: point.x - 18, y: height - point.y - 18, width: 36, height: 36), position: position)
    }

    func show(group: AppGroup, anchor: CGRect, position: DockPosition = .bottom) {
        if currentGroupID == group.id { hide(restoreFocus: true); return }
        // 先提交旧组的编辑，再切换模型，避免字段编辑器把旧名称写进新组。
        if content?.group.id != group.id { panel?.makeFirstResponder(nil) }
        generation += 1
        self.anchor = anchor
        self.position = position
        if !visibilityHeld { previousApplication = NSWorkspace.shared.frontmostApplication }
        if panel == nil { makePanel(group: group) }
        guard let panel, let content else { return }
        isOpen = true
        presentedAt = ProcessInfo.processInfo.systemUptime
        pendingExternalDismissal = false
        content.setGroup(group)
        content.setBadges(badges)
        panel.title = "DockApex · 分组：\(group.name)"
        panel.setAccessibilityTitle(panel.title)
        layoutPanel(scrollToTop: true)
        content.prepareForPresentation(keyboard: NSApp.currentEvent?.type == .keyDown)
        content.prewarmDragGhost()
        if !visibilityHeld { visibilityHeld = true; onVisibility(true) }
        presentation?.present()
        panel.makeFirstResponder(content)
        installMonitors()
    }

    /// 数据刷新不切换开关状态，也不抢走正在输入的名称。
    func refresh(group: AppGroup) {
        guard currentGroupID == group.id else { return }
        panel?.title = "DockApex · 分组：\(group.name)"
        panel?.setAccessibilityTitle(panel?.title ?? "")
        guard content?.group != group else { return }
        content?.setGroup(group)
        panel?.title = "DockApex · 分组：\(group.name)"
        layoutPanel()
    }

    func updateBadges(_ badges: [String: String]) { self.badges = badges; content?.setBadges(badges) }

    func updateAnchor(_ anchor: CGRect) {
        guard currentGroupID != nil, self.anchor != anchor else { return }
        if content?.isDragging == true { pendingAnchor = anchor; return }
        self.anchor = anchor
        layoutPanel()
    }

    func hide(restoreFocus: Bool = false, reason: String = "explicit", animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        pendingAnchor = nil
        pendingExternalDismissal = false
        lastDismissalReason = reason
        content?.cancelLocalDrag(animated: false)
        content?.stopPresentationMotion()
        content?.stopLaunchBounce()
        content?.hideNameHint()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        // 收起一开始就释放应用栏，图标立即按指针位置复原，不等关闭动画回调（回调可能被新布局打断）。
        if visibilityHeld { visibilityHeld = false; onVisibility(false) }
        presentation?.dismiss(animated: animated) {}
        if restoreFocus, let previousApplication,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate()
        }
    }

    /// 预建面板与玻璃视图，避免第一次展开时在主线程完成窗口/材质初始化。
    func prewarm(_ group: AppGroup) {
        guard panel == nil else { return }
        makePanel(group: group)
        content?.setGroup(group)
        content?.layoutSubtreeIfNeeded()
        content?.prewarmDragGhost()
        panel?.orderOut(nil)
    }

    private func makePanel(group: AppGroup) {
        let panel = GroupPopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // 分组面板必须高于应用栏（22）和补底/标签遮盖（21），否则面板底部的成员名称会被盖住。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        let content = GroupGridView(group: group)
        content.onChanged = { [weak self] group in self?.onChanged(group); self?.layoutPanel() }
        content.onDragFinished = { [weak self] in
            guard let self else { return }
            self.dismissAfterExternalActivationIfReady()
            let token = self.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, let anchor = self.pendingAnchor else { return }
                self.pendingAnchor = nil; self.updateAnchor(anchor)
            }
        }
        content.onClose = { [weak self] restore in self?.hide(restoreFocus: restore) }
        content.onInteractionFinished = { [weak self] in self?.dismissAfterExternalActivationIfReady() }
        content.animatesLaunch = animatesLaunch
        let surface = PopupSurfaceView(content: content, radius: 24)
        panel.contentView = surface
        self.content = content
        self.panel = panel
        presentation = PopupPresentation(panel: panel, surface: surface, kind: "group")
    }

    private func dismissAfterExternalActivationIfReady() {
        guard isOpen, pendingExternalDismissal,
              content?.isDragging != true, content?.isPresentingMenu != true, content?.isLaunching != true else { return }
        pendingExternalDismissal = false
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        hide(reason: "external-activation")
    }

    private func layoutPanel(scrollToTop: Bool = false, resizeAnimated: Bool = false) {
        // 收起过程中不再重新排版，否则会打断收起流程，面板以图标大小残留在应用栏上。
        guard isOpen, panel != nil, let content else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 正在拖入时多算一个位置，面板提前长出空位。
        let count = content.group.apps.count + content.incomingCount
        // 一行固定三格，成员多了往下加行；成员少于三个时也保持三格宽。
        let columns = 3
        let cell = GroupGridDragGeometry.cell
        let width = CGFloat(columns) * cell.width + GroupGridView.inset * 2
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let height = min(CGFloat(rows) * cell.height + GroupGridView.inset * 2, max(200, visible.height - 32))
        let desired: CGPoint
        switch position {
        case .bottom: desired = CGPoint(x: anchor.midX - width / 2, y: anchor.maxY + 12)
        case .left: desired = CGPoint(x: anchor.maxX + 12, y: anchor.midY - height / 2)
        case .right: desired = CGPoint(x: anchor.minX - width - 12, y: anchor.midY - height / 2)
        }
        let rect = CGRect(x: min(max(desired.x, visible.minX + 12), visible.maxX - width - 12),
                          y: min(max(desired.y, visible.minY + 12), visible.maxY - height - 12), width: width, height: height)
        content.configure(columns: columns)
        if resizeAnimated { presentation?.resizeVisible(to: rect, anchor: anchor, position: position) }
        else { presentation?.setLayout(frame: rect, anchor: anchor, position: position) }
        if scrollToTop { content.scrollToFirstRow() }
    }

    private func installMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        let token = generation
        let openedAt = ProcessInfo.processInfo.systemUptime
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.generation == token else { return false }
                if event.type != .keyDown, event.timestamp > 0, event.timestamp < openedAt { return false }
                if event.type != .keyDown, let point = self.presentation?.canvasClickOutsideContent(event) {
                    // 展开动画还没走完时画布盖着应用栏上的入口：再次点入口照常收起，点别处按点外部收起。
                    if self.anchor.insetBy(dx: -4, dy: -4).contains(point) { self.hide(restoreFocus: true, reason: "anchor-during-open") }
                    else { self.hide(reason: "canvas-outside") }
                    return true
                }
                if event.window === self.panel { self.presentation?.finishOpeningForInteraction() }
                if event.type == .keyDown, DockMenuPopover.shared.isShown { return false }
                if event.type == .keyDown, event.keyCode == 53 {
                    if self.content?.isDragging == true { self.content?.cancelLocalDrag(); return true }
                    self.hide(restoreFocus: true); return true
                }
                if event.type != .keyDown, event.window !== self.panel {
                    if self.content?.isPresentingMenu == true || self.content?.isDragging == true { return false }
                    // 点窗口预览（弹出框挂在面板上）不算点外面，否则面板先收起、预览随之消失，点不中缩略图。
                    if WindowPreviewController.shared.owns(event.window) { return false }
                    // 栏内点击由同一进程直接切换；无需时间与距离猜测。
                    if event.window?.title.hasPrefix("DockApex · 应用栏") != true { self.hide(reason: "local-outside") }
                }
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            let location = event.cgEvent?.location
            let isPrimaryClick = event.type == .leftMouseDown
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, timestamp == 0 || timestamp >= openedAt,
                      self.content?.isDragging != true, self.content?.isPresentingMenu != true else { return }
                // 原生分组入口的再次点击由启动 URL 切换开关，不能在按下时先关、松手后又重开。
                if isPrimaryClick, let location {
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    let point = CGPoint(x: location.x, y: top - location.y)
                    if self.anchor.insetBy(dx: -4, dy: -4).contains(point) { return }
                }
                self.hide(reason: "global-outside")
            }
        }
    }
}

@MainActor
private final class GroupPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class GroupGridView: NSView {
    /// 面板四周留白；只有图标网格，没有标题行。
    static let inset: CGFloat = 12
    private(set) var group: AppGroup
    var onChanged: ((AppGroup) -> Void)?
    var onClose: ((Bool) -> Void)?
    var onDragFinished: (() -> Void)?
    var onInteractionFinished: (() -> Void)?
    var isPresentingMenu = false
    private let scroll = NSScrollView()
    private let nameHint = GroupNameHint()
    private let grid = GroupDragDocumentView()
    private var tiles: [GroupTileView] = []
    private var columns = 3
    private var selected = 0
    private var typed = ""
    private var typedAt: TimeInterval = 0
    private var badges: [String: String] = [:]
    private var keyboardNavigationActive = false
    private var dragSource: String?
    private var dragGap = 0
    private var dragGrabOffset = CGPoint.zero
    private var dragScreenPoint = CGPoint.zero
    private var dragOriginalIDs: [String] = []
    private var targetFrames: [String: CGRect] = [:]
    private var motionDisplayLink: CADisplayLink?
    private var lastMotionTime: TimeInterval = 0
    private var lastDragEventTime: TimeInterval = 0
    private var hardwareDragObservedDown = false
    private var animateNextLayout = false
    private var pendingGroup: AppGroup?
    /// 应用栏上的应用拖到面板上时让出的空位；成员顺序在松开前不变。
    private var incomingGap: Int?
    /// 成员拖出面板：交给应用栏预览，面板里保留它的空位。
    private var outsidePanel = false
    private var ghostPanel: NSPanel?
    private var ghostView: GroupLocalDragGhost?
    var isDragging: Bool { dragSource != nil }
    var animatesLaunch = true
    /// 正在原地跳动的成员；跳完才收起面板，期间被启动的应用激活也先不收。
    private weak var launchingTile: GroupTileView?
    var isLaunching: Bool { launchingTile != nil }
    var incomingCount: Int { incomingGap == nil ? 0 : 1 }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(group: AppGroup) {
        self.group = group
        super.init(frame: .zero)
        setAccessibilityLabel(group.name)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        addSubview(scroll)
        registerForDraggedTypes([.fileURL])
        rebuild()
    }
    required init?(coder: NSCoder) { nil }
    func configure(columns: Int) { self.columns = columns; needsLayout = true }
    func prepareForPresentation(keyboard: Bool) {
        keyboardNavigationActive = keyboard
        updateKeyboardHighlights()
    }
    func scrollToFirstRow() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, grid.bounds.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func setGroup(_ group: AppGroup) {
        if self.group.id != group.id {
            stopLaunchBounce()
            cancelLocalDrag(animated: false)
            incomingGap = nil
            pendingGroup = nil
            selected = 0
        } else if isDragging {
            pendingGroup = group
            return
        }
        self.group = group
        setAccessibilityLabel(group.name)
        rebuild()
    }
    func refreshRuntime() {
        let snapshots = DockIconProvider.shared.runtimeAppearance(for: group.apps)
        for tile in tiles { if let snapshot = snapshots[tile.app.path] { tile.setRuntime(snapshot) } }
    }
    func setBadges(_ badges: [String: String]) {
        self.badges = badges
        for tile in tiles { tile.badge = badges[tile.app.path] }
    }
    private func rebuild() {
        let existing = Dictionary(tiles.map { ($0.app.path, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = Set(group.apps.map(\.path))
        for tile in tiles where !paths.contains(tile.app.path) { tile.removeFromSuperview() }
        tiles = group.apps.map { app in
            let tile = existing[app.path] ?? GroupTileView(app: app)
            tile.owner = self
            tile.badge = badges[app.path]
            tile.onOpen = { [weak self, weak tile] flags in
                guard let self else { return }
                // 与应用栏一致：只有真正启动（未在运行、不是 ⌘ 单击显示位置）才跳动。
                let launches = flags.intersection([.command, .option]) != .command && ShelfAppActions.running(app) == nil
                ShelfAppActions.open(app, modifiers: flags)
                guard launches, animatesLaunch, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let tile else {
                    onClose?(false); return
                }
                stopLaunchBounce()
                launchingTile = tile
                tile.bounce(until: { ShelfAppActions.running(app) != nil }) { [weak self] in
                    self?.launchingTile = nil
                    self?.onClose?(false)
                }
            }
            tile.onContext = { [weak self] in self?.menu(for: app) ?? NSMenu() }
            if tile.superview == nil { grid.addSubview(tile) }
            return tile
        }
        refreshRuntime()
        selected = min(selected, max(0, tiles.count - 1))
        setAccessibilityChildren(tiles)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let inset = Self.inset
        scroll.frame = CGRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - inset * 2))
        let rows = max(1, (tiles.count + incomingCount + columns - 1) / columns)
        grid.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width,
                            height: max(scroll.contentSize.height, CGFloat(rows) * GroupGridDragGeometry.cell.height))
        updateTargetFrames()
        // 让位动画进行中（例如面板正在加行）只更新目标，继续平滑过去，不直接跳到位。
        if isDragging || animateNextLayout || motionDisplayLink != nil {
            animateNextLayout = false
            startMotion()
        } else { for tile in tiles { if let frame = targetFrames[tile.app.path] { tile.frame = frame } } }
        updateKeyboardHighlights()
    }
    private func updateKeyboardHighlights() {
        for (index, tile) in tiles.enumerated() {
            tile.keyboardSelected = keyboardNavigationActive && window?.firstResponder === self && selected == index
        }
        // 键盘选中时也显示名称，与应用栏键盘导航一致。
        if let tile = tiles.first(where: \.keyboardSelected) { showNameHint(for: tile) }
    }

    func tileHovered(_ tile: GroupTileView, inside: Bool) {
        if inside, !isDragging { showNameHint(for: tile) } else { nameHint.hide(for: tile) }
        // 运行中的成员停 0.3 秒弹窗口预览，箭头对准成员图标。
        guard inside, !isDragging, ShelfAppActions.running(tile.app) != nil else {
            WindowPreviewController.shared.hover(nil, source: .group) { nil }
            return
        }
        // 与成员的右键菜单同一个定位：格子里的图标、向上弹出。
        WindowPreviewController.shared.hover(tile.app, source: .group) { [weak tile] in
            guard let tile else { return nil }
            let icon = tile.iconRect
            return .init(view: tile, rect: CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: icon.height + 3), edge: .maxY)
        }
    }

    func hideNameHint() { nameHint.hide() }

    private func showNameHint(for tile: GroupTileView) {
        guard !WindowPreviewController.shared.isShown, let window = tile.window, window.isVisible else { return }
        nameHint.show(tile.app.name, above: window.convertToScreen(tile.convert(tile.iconRect, to: nil)), for: tile)
    }

    func tilePressed(_ tile: GroupTileView) {
        if let index = tiles.firstIndex(where: { $0 === tile }) { selected = index }
        keyboardNavigationActive = false
        window?.makeFirstResponder(self)
        updateKeyboardHighlights()
    }

    func stopLaunchBounce() { launchingTile?.stopBounce(); launchingTile = nil }

    func beginLocalDrag(_ tile: GroupTileView, event: NSEvent, initialEvent: NSEvent) {
        // 跳动中又拖起成员：不再在跳完后替用户收起面板。
        stopLaunchBounce()
        let started = ProcessInfo.processInfo.systemUptime
        defer { Self.logSlow("组内开始拖动", since: started) }
        nameHint.hide()
        guard !isDragging, let window, group.apps.contains(where: { $0.path == tile.app.path }) else { return }
        dragSource = tile.app.path
        dragOriginalIDs = group.apps.map(\.path)
        dragGap = dragOriginalIDs.firstIndex(of: tile.app.path) ?? 0
        let originalMouse = window.convertPoint(toScreen: initialEvent.locationInWindow)
        let iconRect = window.convertToScreen(tile.convert(tile.iconRect, to: nil))
        dragGrabOffset = CGPoint(x: originalMouse.x - iconRect.minX, y: originalMouse.y - iconRect.minY)
        dragScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        lastDragEventTime = ProcessInfo.processInfo.systemUptime
        hardwareDragObservedDown = NSEvent.pressedMouseButtons & 1 != 0
        tile.alphaValue = 0
        makeLocalGhost(for: tile.app)
        moveLocalDrag(tile, event: event)
        startMotion()
    }

    func moveLocalDrag(_ tile: GroupTileView, event: NSEvent) {
        guard dragSource == tile.app.path, let window else { return }
        dragScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        lastDragEventTime = ProcessInfo.processInfo.systemUptime
        if NSEvent.pressedMouseButtons & 1 != 0 { hardwareDragObservedDown = true }
        moveLocalGhost()
        // 全程用同一条本地事件流和同一个浮层；越出面板时交给应用栏预览让位，不切换系统拖放（第一次切换会卡一下）。
        if !window.frame.insetBy(dx: -6, dy: -6).contains(dragScreenPoint) {
            outsidePanel = true
            Self.reportOutside(dragScreenPoint)
            return
        }
        if outsidePanel { outsidePanel = false; Self.reportOutside(nil) }
        updateGap(at: grid.convert(event.locationInWindow, from: nil))
        startMotion()
    }

    private static func reportOutside(_ point: CGPoint?) {
        let started = ProcessInfo.processInfo.systemUptime
        GroupPanelController.referenceDragMoved?(point)
        logSlow("拖出面板预览", since: started)
    }

    func finishLocalDrag(event: NSEvent) {
        guard dragSource != nil, let window else { return }
        endDrag(at: window.convertPoint(toScreen: event.locationInWindow))
    }

    /// 松开：在面板里按空位排序；拖出面板时交给应用栏，栏接收就移出分组，不接收就弹回原位。
    private func endDrag(at screenPoint: CGPoint) {
        guard let source = dragSource, let window else { return }
        let point = grid.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard outsidePanel else {
            updateGap(at: point)
            finishLocalDrag(source: source, point: point, cancelled: false, animated: true)
            return
        }
        outsidePanel = false
        if let app = group.apps.first(where: { $0.path == source }),
           GroupPanelController.referenceDropped?(app.appURL, screenPoint) == true {
            // 应用栏已移出该成员；分组刷新在拖动期间暂存，结束拖动后再应用。
            dragSource = nil; dragOriginalIDs = []; grid.placeholder = nil
            ghostPanel?.alphaValue = 0
            tiles.first(where: { $0.app.path == source })?.alphaValue = 1
            if let pending = pendingGroup { pendingGroup = nil; setGroup(pending) }
            onDragFinished?()
            updateTargetFrames(); startMotion()
            return
        }
        GroupPanelController.referenceDragMoved?(nil)
        finishLocalDrag(source: source, point: point, cancelled: true, animated: true)
    }

    /// 返回是否开始或结束了拖入（面板要相应加行或收回）。
    func updateIncoming(at screenPoint: CGPoint?) -> Bool {
        guard dragSource == nil, let window else { return false }
        guard let screenPoint else {
            guard incomingGap != nil else { return false }
            incomingGap = nil
            animateNextLayout = true
            updateTargetFrames(); startMotion()
            return true
        }
        let point = grid.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let began = incomingGap == nil
        let gap = GroupGridDragGeometry.gap(at: point, orderedIDs: group.apps.map(\.path), frames: targetFrames, excluding: "",
                                            placeholder: grid.placeholder, currentGap: incomingGap)
        guard gap != incomingGap else { return false }
        incomingGap = gap
        animateNextLayout = true
        updateTargetFrames(); startMotion()
        return began
    }

    func incomingLandingRect() -> CGRect? {
        guard incomingGap != nil, let placeholder = grid.placeholder, let window else { return nil }
        // 与成员格子里图标的位置一致（GroupTileView.iconRect）。
        let icon = CGRect(x: placeholder.minX + (placeholder.width - 54) / 2, y: placeholder.maxY - 62, width: 54, height: 54)
        return window.convertToScreen(grid.convert(icon, to: nil))
    }

    func takeIncomingGap() -> Int? {
        defer { incomingGap = nil }
        return incomingGap
    }

    func cancelLocalDrag(animated: Bool = true) {
        guard let source = dragSource else { return }
        if outsidePanel { outsidePanel = false; GroupPanelController.referenceDragMoved?(nil) }
        let point = grid.convert(window?.convertPoint(fromScreen: dragScreenPoint) ?? .zero, from: nil)
        finishLocalDrag(source: source, point: point, cancelled: true, animated: animated)
    }

    private func finishLocalDrag(source: String, point: CGPoint, cancelled: Bool, animated: Bool) {
        let pending = pendingGroup
        pendingGroup = nil
        let topologyChanged = pending.map { $0.apps.map(\.path) != dragOriginalIDs } ?? false
        let order = GroupGridDragGeometry.reordered(dragOriginalIDs, source: source, gap: dragGap)
        if let tile = tiles.first(where: { $0.app.path == source }) {
            let icon = tile.iconRect
            if animated { tile.frame.origin = CGPoint(x: point.x - dragGrabOffset.x - icon.minX, y: point.y - dragGrabOffset.y - icon.minY) }
            tile.alphaValue = 1
        }
        dragSource = nil
        dragOriginalIDs = []
        grid.placeholder = nil
        ghostPanel?.alphaValue = 0
        onDragFinished?()
        if topologyChanged || cancelled {
            if let pending { group = pending; rebuild() }
            updateTargetFrames()
            if animated { startMotion() }
            else { stopMotion(); installTargetsImmediately() }
            return
        }
        if let pending { group.name = pending.name }
        guard order != group.apps.map(\.path) else { updateTargetFrames(); startMotion(); return }
        let map = Dictionary(group.apps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        group.apps = order.compactMap { map[$0] }
        selected = group.apps.firstIndex(where: { $0.path == source }) ?? 0
        animateNextLayout = true
        commit() // 一次最终提交；鼠标移动和 Esc 取消从不写成员顺序。
        layoutSubtreeIfNeeded()
        updateTargetFrames()
        startMotion()
    }

    private func updateGap(at point: CGPoint) {
        guard let source = dragSource else { return }
        let frames = Dictionary(tiles.map { ($0.app.path, $0.frame) }, uniquingKeysWith: { first, _ in first })
        dragGap = GroupGridDragGeometry.gap(at: point, orderedIDs: dragOriginalIDs, frames: frames, excluding: source,
                                           placeholder: grid.placeholder, currentGap: dragGap)
        updateTargetFrames()
    }

    private func updateTargetFrames() {
        let ids = group.apps.map(\.path)
        var order = DockMotionLayout.projectedOrder(ids, draggedID: dragSource, insertionGap: dragSource == nil ? nil : dragGap)
        if dragSource == nil, let incomingGap { order.insert(nil, at: min(incomingGap, order.count)) }
        targetFrames = GroupGridDragGeometry.frames(order: order, columns: columns, documentHeight: grid.bounds.height)
        if let index = order.firstIndex(where: { $0 == nil }) {
            grid.placeholder = GroupGridDragGeometry.tileFrame(index: index, columns: columns, documentHeight: grid.bounds.height)
        } else { grid.placeholder = nil }
    }

    private func installTargetsImmediately() {
        for tile in tiles { if let frame = targetFrames[tile.app.path] { tile.frame = frame } }
    }

    private func startMotion() {
        guard motionDisplayLink == nil, window != nil else { return }
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        let link = displayLink(target: self, selector: #selector(motionFrame(_:)))
        // 跟随面板所在显示器；120Hz 屏幕不再被固定 60Hz 定时器限速。
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 0)
        motionDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopMotion() { motionDisplayLink?.invalidate(); motionDisplayLink = nil }
    @objc private func motionFrame(_ link: CADisplayLink) { advanceMotion() }

    func stopPresentationMotion() {
        stopMotion()
        installTargetsImmediately()
        ghostPanel?.alphaValue = 0
    }

    private func advanceMotion() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.05, max(0.001, now - lastMotionTime)); lastMotionTime = now
        if dragSource != nil, let window {
            if !outsidePanel {
                autoScrollIfNeeded(delta: delta)
                updateGap(at: grid.convert(window.convertPoint(fromScreen: dragScreenPoint), from: nil))
            }
            if NSEvent.pressedMouseButtons & 1 != 0 { hardwareDragObservedDown = true }
            else if hardwareDragObservedDown, now - lastDragEventTime > 0.1 { endDrag(at: dragScreenPoint) }
        }
        let fraction: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : CGFloat(1 - exp(-delta / 0.06))
        var moving = false
        for tile in tiles where tile.app.path != dragSource {
            guard let target = targetFrames[tile.app.path] else { continue }
            var frame = DockMotionLayout.interpolated(tile.frame, toward: target, fraction: fraction)
            if max(abs(frame.minX - target.minX), abs(frame.minY - target.minY)) < 0.12 { frame = target }
            else { moving = true }
            if tile.frame != frame { tile.frame = frame }
        }
        if dragSource == nil, !moving { stopMotion() }
    }

    private func autoScrollIfNeeded(delta: TimeInterval) {
        guard let window else { return }
        let point = grid.convert(window.convertPoint(fromScreen: dragScreenPoint), from: nil)
        let visible = scroll.documentVisibleRect
        let maximum = max(0, grid.bounds.height - visible.height)
        guard maximum > 0 else { return }
        var y = visible.minY
        let distance = CGFloat(delta) * 300
        if point.y > visible.maxY - 20 { y = min(maximum, y + distance) }
        else if point.y < visible.minY + 20 { y = max(0, y - distance) }
        if y != visible.minY { scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// 预建拖动浮层（启动预建面板时和每次展开时）：第一次拖动不再现建、现排窗口。
    func prewarmDragGhost() { ensureGhostPanel() }

    private static func logSlow(_ step: String, since started: TimeInterval) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        if elapsed > 8 { GroupPanelController.log?(String(format: "%@耗时 %.1f ms", step, elapsed)) }
    }

    private func makeLocalGhost(for app: AppReference) {
        ensureGhostPanel()
        // 直接用格子里已经画好的图标，不在拖动开始时重新取 App 图标。
        ghostView?.image = tiles.first(where: { $0.app.path == app.path })?.displayedImage ?? ShelfAppActions.icon(app)
        moveLocalGhost()
        if ghostPanel?.isVisible == false { ghostPanel?.orderFrontRegardless() }
        ghostPanel?.alphaValue = 1
    }

    private func ensureGhostPanel() {
        guard ghostPanel == nil else { return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 54, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "DockApex · 分组拖动"
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true; panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        let view = GroupLocalDragGhost(); panel.contentView = view
        ghostPanel = panel; ghostView = view
        // 建好就透明地留在屏上：拖动时只改透明度和位置。现排窗口要同步等 WindowServer，忙时一次就是几十到几百毫秒。
        panel.alphaValue = 0
        panel.orderFrontRegardless()
    }

    private func moveLocalGhost() {
        ghostPanel?.setFrameOrigin(CGPoint(x: dragScreenPoint.x - dragGrabOffset.x, y: dragScreenPoint.y - dragGrabOffset.y))
    }

    override func becomeFirstResponder() -> Bool { updateKeyboardHighlights(); return true }
    override func resignFirstResponder() -> Bool { for tile in tiles { tile.keyboardSelected = false }; nameHint.hide(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, dragSource != nil { cancelLocalDrag(); return }
        guard !tiles.isEmpty else { return }
        keyboardNavigationActive = true
        switch event.keyCode {
        case 53: onClose?(true)
        case 123: selected = max(0, selected - 1)
        case 124: selected = min(tiles.count - 1, selected + 1)
        case 126: selected = max(0, selected - columns)
        case 125: selected = min(tiles.count - 1, selected + columns)
        case 36, 76, 49:
            if event.modifierFlags.contains(.control) { popMenu(for: tiles[selected]) }
            else { tiles[selected].onOpen?(event.modifierFlags) }
        case 115: selected = 0
        case 119: selected = tiles.count - 1
        default:
            let now = ProcessInfo.processInfo.systemUptime
            typed = now - typedAt > 0.8 ? "" : typed
            typedAt = now
            if let chars = event.charactersIgnoringModifiers, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                typed += chars
                if let index = tiles.firstIndex(where: { $0.app.name.localizedLowercase.hasPrefix(typed.localizedLowercase) }) { selected = index }
            } else { super.keyDown(with: event) }
        }
        updateKeyboardHighlights()
        tiles[selected].scrollToVisible(tiles[selected].bounds)
    }
    private func popMenu(for tile: GroupTileView) { presentMenu(menu(for: tile.app), from: tile, keyboard: true) }

    /// 与应用栏一致用系统弹出框，箭头指向格子里的图标；关闭前分组面板不因点到菜单而收起。
    func presentMenu(_ menu: NSMenu, from tile: GroupTileView, keyboard: Bool) {
        isPresentingMenu = true
        let icon = tile.iconRect
        DockMenuPopover.shared.show(menu, from: tile, rect: CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: icon.height + 3),
                                    edge: .maxY, byPress: NSEvent.pressedMouseButtons != 0, keyboard: keyboard) { [weak self] in
            self?.isPresentingMenu = false
            self?.onInteractionFinished?()
        }
    }
    private func menu(for app: AppReference) -> NSMenu {
        // 组内顺序直接拖动调整，菜单里只留移出分组。
        let extra: [NSMenuItem] = [
            ShelfMenuItem("移除分组") { [weak self] in
                guard let self else { return }; self.group.apps.removeAll { $0.path == app.path }; self.commit()
            }
        ]
        let menu = ShelfAppActions.applicationMenu(app, extraItems: extra, onActivate: { [weak self] in self?.onClose?(false) })
        if menu.delegate == nil { menu.delegate = MenuAppearance.shared }
        return menu
    }
    private func commit() { pendingGroup = nil; rebuild(); onChanged?(group) }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        let reference = sender.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType("io.daliang.dockfolders.application-reference")) == true
        return reference && sender.draggingSourceOperationMask.contains(.move) ? .move
            : DockMotionSurface.referenceOperation(sender.draggingSourceOperationMask)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let point = grid.convert(sender.draggingLocation, from: nil)
        let targetIndex = tiles.firstIndex { $0.frame.contains(point) }
        let apps = urls.compactMap(AppReference.init(url:))
        // 混合文件拖到应用上时交给目标应用，避免只接受其中的 App 而丢弃其余文件。
        if !apps.isEmpty, apps.count != urls.count {
            guard let index = targetIndex else { return false }
            ShelfAppActions.openFiles(urls, with: tiles[index].app); onClose?(false); return true
        }
        if apps.isEmpty {
            guard let index = targetIndex else { return false }
            ShelfAppActions.openFiles(urls, with: tiles[index].app)
            onClose?(false)
            return true
        }
        let finder = "/System/Library/CoreServices/Finder.app"
        let moving = apps.filter { $0.path != finder && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        guard !moving.isEmpty else { return false }
        let sourcePaths = Set(moving.map(\.path))
        let before = targetIndex.map { Array(group.apps.prefix($0)) } ?? group.apps
        let insertion = before.filter { !sourcePaths.contains($0.path) }.count
        group.apps.removeAll { sourcePaths.contains($0.path) }
        group.apps.insert(contentsOf: moving, at: min(insertion, group.apps.count))
        commit()
        return true
    }
}

/// 组内成员名称：与应用栏同款玻璃胶囊，出现在图标正上方。
@MainActor
private final class GroupNameHint {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var owner: ObjectIdentifier?

    func show(_ text: String, above anchor: CGRect, for tile: AnyObject) {
        if panel == nil { let made = HintBubbleView.makePanel(title: "DockApex · 分组成员名称"); panel = made.0; label = made.1 }
        guard let panel, let label else { return }
        owner = ObjectIdentifier(tile)
        if label.stringValue != text { label.stringValue = text }
        let size = CGSize(width: min(360, ceil(label.fittingSize.width) + 26), height: HintBubbleView.bodyHeight + HintBubbleView.tailHeight)
        let safe = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: min(max(anchor.midX - size.width / 2, safe.minX + 5), safe.maxX - size.width - 5),
                             y: min(anchor.maxY + 5.5, safe.maxY - size.height - 5))
        let frame = CGRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        (panel.contentView as? HintBubbleView)?.tailX = (anchor.midX - origin.x).rounded()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 传入成员时只撤掉它自己的提示，避免从一个图标移到相邻图标时先显示新名称又被旧图标的离开事件撤掉。
    func hide(for tile: AnyObject? = nil) {
        if let tile, owner != ObjectIdentifier(tile) { return }
        owner = nil
        panel?.orderOut(nil)
    }
}

@MainActor
private final class GroupTileView: NSView {
    let app: AppReference
    weak var owner: GroupGridView?
    var onOpen: ((NSEvent.ModifierFlags) -> Void)?
    var onContext: (() -> NSMenu)?
    var keyboardSelected = false { didSet { needsDisplay = true } }
    var badge: String? { didSet { if oldValue != badge { needsDisplay = true; setAccessibilityValue(badge) } } }
    private var runtimeImage: NSImage?
    var displayedImage: NSImage? { runtimeImage }
    private var runtimeIsRunning = false
    private var pressed = false
    private var down: NSEvent?
    private var bounceToken = 0
    private var didLocalDrag = false
    var iconRect: CGRect { CGRect(x: (bounds.width - 54) / 2, y: bounds.height - 62, width: 54, height: 54) }
    init(app: AppReference) {
        self.app = app
        super.init(frame: .zero)
        // 组内让位只移动已有图层；图标在状态改变时才重新绘制。
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(app.name)
        setAccessibilityIdentifier("group-app:" + app.path)
        // 名称不常显，与应用栏一致：指针停在图标上才出现提示。
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { owner?.tileHovered(self, inside: true) }
    override func mouseExited(with event: NSEvent) { owner?.tileHovered(self, inside: false) }
    func setRuntime(_ snapshot: DockIconProvider.RuntimeAppearance) {
        guard runtimeImage !== snapshot.image || runtimeIsRunning != snapshot.isRunning else { return }
        runtimeImage = snapshot.image; runtimeIsRunning = snapshot.isRunning
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if keyboardSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        }
        // 按下与应用栏一致，照系统 Dock 堆栈：只把图标颜色乘 0.4，不画选框、不改透明度。
        if pressed, let runtimeImage, let context = NSGraphicsContext.current?.cgContext {
            DockPressDarkening.drawPressed(in: context, rect: iconRect) { runtimeImage.draw(in: iconRect) }
        } else {
            runtimeImage?.draw(in: iconRect)
        }
        if runtimeIsRunning {
            NSColor.labelColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - 2, y: 3, width: 4, height: 4)).fill()
        }
        if let badge, !badge.isEmpty {
            let text = badge.count > 4 ? "•" : badge
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
            let width = max(16, (text as NSString).size(withAttributes: attributes).width + 8)
            let rect = CGRect(x: bounds.midX + 16 - width / 2, y: bounds.height - 18, width: width, height: 16)
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            (text as NSString).draw(at: CGPoint(x: rect.midX - (text as NSString).size(withAttributes: attributes).width / 2, y: rect.minY + 2), withAttributes: attributes)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        down = event; didLocalDrag = false; pressed = true; needsDisplay = true
        owner?.tilePressed(self)
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        let wasDragging = didLocalDrag
        let activate = pressed && !wasDragging && bounds.contains(convert(event.locationInWindow, from: nil))
        down = nil; pressed = false; needsDisplay = true
        didLocalDrag = false
        if wasDragging { owner?.finishLocalDrag(event: event) }
        else if activate { onOpen?(event.modifierFlags) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        if didLocalDrag { owner?.moveLocalDrag(self, event: event); return }
        let origin = convert(down.locationInWindow, from: nil)
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(origin.x - now.x, origin.y - now.y) > 5 else { return }
        didLocalDrag = true; pressed = false; needsDisplay = true
        owner?.beginLocalDrag(self, event: event, initialEvent: down)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContext?() { owner?.presentMenu(menu, from: self, keyboard: false) }
    }
    override func rightMouseDragged(with event: NSEvent) { DockMenuPopover.shared.trackPress(at: NSEvent.mouseLocation) }
    override func rightMouseUp(with event: NSEvent) { DockMenuPopover.shared.releasePress(at: NSEvent.mouseLocation) }
    override func accessibilityPerformPress() -> Bool { onOpen?([]); return true }

    /// 启动跳动，节奏与应用栏一致：每下约 0.39 秒，最多三下；跳完一下才检查是否已启动，不在半空停住。
    /// 高度 10 点：首行图标跳到最高时刚好碰到滚动区顶边，不被裁掉。
    func bounce(until finished: @escaping () -> Bool, completion: @escaping () -> Void) {
        bounceToken += 1
        hop(token: bounceToken, count: 0, finished: finished, completion: completion)
    }

    func stopBounce() {
        bounceToken += 1
        layer?.removeAnimation(forKey: "launch-bounce")
    }

    private func hop(token: Int, count: Int, finished: @escaping () -> Bool, completion: @escaping () -> Void) {
        guard token == bounceToken else { return }
        guard let layer, count < 3, count == 0 || !finished() else { bounceToken += 1; completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.hop(token: token, count: count + 1, finished: finished, completion: completion) }
        }
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = [0, 10, 0]
        lift.keyTimes = [0, 0.5, 1]
        lift.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        lift.duration = .pi / 8
        layer.add(lift, forKey: "launch-bounce")
        CATransaction.commit()
    }
}

@MainActor
private final class GroupDragDocumentView: NSView {
    var placeholder: CGRect? { didSet { if placeholder != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        guard let placeholder else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: placeholder.insetBy(dx: 3, dy: 3), xRadius: 12, yRadius: 12).fill()
    }
}

@MainActor
private final class GroupLocalDragGhost: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.9) }
}

/// 管理窗口的批量文件 URL 入口，与网格拖放使用相同的应用引用解析。
@MainActor
@discardableResult
func acceptApplicationURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
    let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !providers.isEmpty else { return false }
    for provider in providers {
        provider.loadObject(ofClass: NSURL.self) { item, _ in
            if let url = item as? URL, url.isFileURL { Task { @MainActor in completion([url]) } }
        }
    }
    return true
}
