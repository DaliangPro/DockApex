import AppKit
import QuartzCore

struct DockBarAppearance: Equatable, Sendable {
    var iconSize: CGFloat = 37
    var maxIconSize: CGFloat = 62
    var magnification = true
    var showRunningIndicators = true
    var animateLaunching = true
    var hideDelay: TimeInterval = 0.55
    static let nativeDefaults = DockBarAppearance()
}

/// 窗口显隐、交互保持和屏幕迁移共用状态，普通点击不激活本应用。
@MainActor
final class DockBarController: NSObject {
    var onGeometryChanged: (() -> Void)?
    /// 应用栏是否正在屏幕上（含自动隐藏/全屏时的唤出过程）。
    var onPresentationChanged: ((Bool) -> Void)?
    /// 自制菜单打开/关闭；用于暂停标签遮盖，避免把系统菜单截进遮盖画面。
    var onMenuState: ((Bool) -> Void)?
    private(set) var isPresented = false
    private(set) var isHovering = false
    private(set) var isNear = false
    private let onOpen: (String, CGPoint) -> Void
    private let onMerge: (String, String) -> Void
    private let onReorder: (String, Int) -> Void
    private let onExternalDrop: (DockExternalDrop) -> Void
    private let onContext: (String) -> NSMenu
    private let onRemove: (String) -> Void
    private let onFocus: (Bool) -> Void
    private var panel: DockMotionPanel?
    private var surface: DockMotionSurface?
    private var hintPanel: NSPanel?
    private var hintLabel: NSTextField?
    private var hintBubble: HintBubbleView?
    private var hintStrip = CGRect.zero
    private var suppressesHint = false
    private var items: [DockDisplayItem] = []
    private var position = DockPosition.bottom
    private var appearance = DockBarAppearance.nativeDefaults
    private var autoHide = false
    private var configuredAutoHide = false
    private var fullscreenDisplays = Set<UInt32>()
    private var enabled = false
    private var screen: NSScreen?
    private var pinnedDisplayUUID: String?
    private var targetFrame = CGRect.zero
    private var presentedFrame = CGRect.zero
    private var exposure: CGFloat = 0
    private var wantsVisible = false
    private var hideDeadline: TimeInterval?
    private var holds = Set<String>()
    private var pointerCapture = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var frameDisplayLink: CADisplayLink?
    private var frameDisplayID: UInt32?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastFrameTime: TimeInterval = 0
    private var pendingScreen: (id: UInt32, since: TimeInterval)?
    private var pendingShow: (items: [DockDisplayItem], position: DockPosition, autoHide: Bool, appearance: DockBarAppearance)?
    private var showGeneration = 0
    private var lastPointer: CGPoint?
    private var eventPointer: (point: CGPoint, hardware: CGPoint, timestamp: TimeInterval)?
    private var previousReservedArea: DockReservedArea?
    private struct HintMeasurementKey: Equatable {
        let text: String
        let font: NSFont?
        let appearance: NSAppearance.Name
        let displayID: UInt32?
        let screenFrame: CGRect?
        let safeFrame: CGRect
        let backingScale: CGFloat?
    }
    private var hintMeasurement: (key: HintMeasurementKey, size: CGSize)?
    private var lastHint: (text: String, frame: CGRect)?
    private var frameCadence = DockFrameCadence()
    private var frameStartedAt: TimeInterval?
    private var lastFramePointer: CGPoint?
    private var lastPointerMotion: TimeInterval = 0
    private var busyObserver: CFRunLoopObserver?
    private var sweep: (started: TimeInterval, duration: TimeInterval, from: CGPoint, to: CGPoint)?

    init(onOpen: @escaping (String, CGPoint) -> Void,
         onMerge: @escaping (String, String) -> Void,
         onReorder: @escaping (String, Int) -> Void,
         onExternalDrop: @escaping (DockExternalDrop) -> Void,
         onContext: @escaping (String) -> NSMenu,
         onRemove: @escaping (String) -> Void = { _ in },
         onFocus: @escaping (Bool) -> Void = { _ in }) {
        self.onOpen = onOpen
        self.onMerge = onMerge
        self.onReorder = onReorder
        self.onExternalDrop = onExternalDrop
        self.onContext = onContext
        self.onRemove = onRemove
        self.onFocus = onFocus
        super.init()
    }

    func show(items: [DockDisplayItem], position: DockPosition, autoHide: Bool,
              appearance: DockBarAppearance = .nativeDefaults) {
        if surface?.isDragging == true {
            pendingShow = (items, position, autoHide, appearance)
            surface?.updateRuntime(items)
            return
        }
        showGeneration += 1
        pendingShow = nil
        let initial = !enabled
        let moved = self.position != position
        let previousAutoHide = self.autoHide
        self.items = items
        self.position = position
        self.configuredAutoHide = autoHide
        self.appearance = appearance
        enabled = true
        if panel == nil { makePanel() }
        ensureHintPanel()
        chooseValidScreen()
        self.autoHide = configuredAutoHide || screen.map { fullscreenDisplays.contains(screenID($0)) } == true
        let hidingChanged = previousAutoHide != self.autoHide
        updateGeometry(snap: initial || moved)
        surface?.update(items: items, position: position, metrics: fittedMetrics(), appearance: appearance)
        installObservers()
        if initial || moved || hidingChanged || !self.autoHide { reveal("show:\(initial ? "i" : "")\(moved ? "m" : "")\(hidingChanged ? "h" : "")\(!self.autoHide ? "a" : "")") }
        if self.autoHide, holds.isEmpty { hideDeadline = hideDeadline ?? now + (initial ? 1.2 : appearance.hideDelay) }
        startFrames()
    }

    /// 使用当前呈现矩形；面板、菜单和 VoiceOver 与用户看到的位置一致。
    func anchorRect(for id: String) -> CGRect? { surface?.screenRect(for: id) }
    func previewAnchor(for id: String) -> WindowPreviewController.Anchor? { surface?.previewAnchor(for: id) }
    /// 未放大时的位置（静止布局），不随指针悬停变化。
    func restingRect(for id: String) -> CGRect? { surface?.restingScreenRect(for: id) }
    func retainGroupAnchor(_ id: String) { surface?.retainGroupAnchor(id) }

    /// 仅诊断用：当前图标在屏幕上的位置，便于验收脚本定位点击与拖动目标。
    var itemFramesForDiagnostics: [[String: Any]] {
        items.compactMap { item in
            guard let rect = anchorRect(for: item.id) else { return nil }
            // 不写名称：最小化窗口的名称就是窗口标题，属于用户内容。
            return ["id": item.id, "isGroup": item.isGroup, "frame": NSStringFromRect(rect)]
        }
    }

    /// 当前指针下的条目 ID（app: / group: / system:window:）。
    var hoveredItemID: String? { surface?.interactionSummary["hot"] as? String }

    var displayUUID: String? { screen.map { DockDisplayDescriptor.uuid(for: $0) } }
    var displayFrame: CGRect? { screen?.frame }
    var isDragging: Bool { surface?.isDragging == true }
    var frameTimingSummary: [String: Any] {
        ["measurement": "最近最多 240 次活跃显示回调；排除空闲暂停间隔。主线程 cadence，不是屏幕合成 FPS。",
         "sampleCount": frameCadence.sampleCount, "intervalCount": frameCadence.intervalCount,
         "intervalP95Ms": frameCadence.intervalP95 * 1_000,
         "intervalMaxMs": frameCadence.maximumInterval * 1_000,
         "intervalsOverOneAndHalfFrames": frameCadence.delayedIntervalCount,
         "callbackWorkP95Ms": frameCadence.workP95 * 1_000,
         "callbackWorkMaxMs": frameCadence.maximumWork * 1_000,
         "frameBusyP95Ms": frameCadence.busyP95 * 1_000,
         "frameBusyMaxMs": frameCadence.maximumBusy * 1_000,
         "interaction": surface?.interactionSummary ?? [:], "reveals": revealLog,
         "pointer": ["current": NSStringFromPoint(currentPointer), "hardware": NSStringFromPoint(NSEvent.mouseLocation),
                     "event": eventPointer.map { NSStringFromPoint($0.point) + " hw " + NSStringFromPoint($0.hardware) } ?? "",
                     "inside": surface?.containsScreenPoint(currentPointer) == true, "frames": frameDisplayLink.map { !$0.isPaused } ?? false,
                     "panel": panel.map { NSStringFromRect($0.frame) } ?? "", "ignores": panel?.ignoresMouseEvents == true]]
    }
    var reservedArea: DockReservedArea? {
        guard enabled, !autoHide, let screen, let displayUUID else { return nil }
        let frame = screen.frame
        let thickness = DockMotionLayout.restingThickness(metrics: fittedMetrics())
        let reserved: CGRect
        switch position {
        case .bottom: reserved = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        case .left: reserved = CGRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        case .right: reserved = CGRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        }
        return DockReservedArea(displayUUID: displayUUID, screenFrame: frame, reservedFrame: reserved, position: position)
    }

    /// nil 使用原生风格的屏幕边缘停留迁移；指定 UUID 的控制器始终留在该屏。
    func setDisplay(uuid: String?) {
        let previous = displayUUID
        pinnedDisplayUUID = uuid
        chooseValidScreen()
        guard enabled, previous != displayUUID else { return }
        updateGeometry(snap: true)
        applyFullscreenPolicy()
        surface?.update(items: items, position: position, metrics: fittedMetrics(), appearance: appearance)
        startFrames()
    }

    func setFullscreenDisplays(_ displays: Set<UInt32>) {
        fullscreenDisplays = displays
        applyFullscreenPolicy()
    }

    private func applyFullscreenPolicy() {
        let next = configuredAutoHide || screen.map { fullscreenDisplays.contains(screenID($0)) } == true
        guard next != autoHide else { return }
        autoHide = next
        if next, holds.isEmpty { hideDeadline = now + 0.08; startFrames() }
        else if !next { reveal("fullscreen-off") }
        notifyGeometryChanged()
    }

    func setInteractionHold(_ reason: String, active: Bool) {
        if active { holds.insert(reason); reveal("hold:\(reason)") }
        else {
            guard holds.remove(reason) != nil else { return }
            if holds.isEmpty { hideDeadline = now + appearance.hideDelay; surface?.releaseActiveGroup() }
        }
        // 分组/文件面板打开时，应用栏自己的名称提示会浮在面板之上；先收掉并暂停，关闭后恢复。
        if reason == "group" || reason == "files" {
            suppressesHint = active
            if active { showHint(nil, anchor: .zero) }
        }
        if reason == "menu" { onMenuState?(active) }
    }

    func hide() {
        enabled = false
        pendingShow = nil
        hideDeadline = nil
        holds.removeAll()
        surface?.cancelInteraction()
        surface?.releaseActiveGroup()
        stopFrames()
        // 观察者只加不撤的话，切换显示模式重建应用栏时会越积越多。
        if let busyObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), busyObserver, .commonModes); self.busyObserver = nil }
        pollTimer?.invalidate(); pollTimer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        globalMonitor = nil; localMonitor = nil; screenObserver = nil
        exposure = 0; wantsVisible = false
        if isPresented { isPresented = false; onPresentationChanged?(false) }
        panel?.orderOut(nil)
        hintPanel?.orderOut(nil)
        notifyGeometryChanged()
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func chooseValidScreen() {
        if let pinnedDisplayUUID {
            screen = NSScreen.screens.first { DockDisplayDescriptor.uuid(for: $0) == pinnedDisplayUUID } ?? NSScreen.screens.first
        } else if let screen, let current = eligibleScreens.first(where: { screenID($0) == screenID(screen) }) {
            self.screen = current
        } else {
            screen = eligibleScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? eligibleScreens.first
        }
        if let screen {
            panel?.title = "DockApex · 应用栏 · \(screen.localizedName)"
            panel?.setAccessibilityTitle(panel?.title)
        }
    }

    private var eligibleScreens: [NSScreen] {
        if pinnedDisplayUUID != nil {
            // 指定屏幕已在 setDisplay / 屏幕变化通知中解析；指针轮询无需重复向 WindowServer 查 UUID。
            return (screen ?? NSScreen.screens.first).map { [$0] } ?? []
        }
        // 这是本应用的窗口，不沿用系统 Dock 在共享 Spaces 模式下仅显示主屏的限制。
        return NSScreen.screens
    }

    private func fittedMetrics() -> DockMotionMetrics {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let length = (position == .bottom ? frame.width : frame.height) - 50
        let available = (length - CGFloat(max(0, items.count - 1)) * 7 - 60) / CGFloat(max(1, items.count))
        let base = min(max(16, appearance.iconSize), max(16, available))
        return DockMotionMetrics(iconSize: base, maximumIconSize: max(base, min(128, appearance.maxIconSize)), magnification: appearance.magnification)
    }

    private func updateGeometry(snap: Bool) {
        guard let screen else { return }
        let metrics = fittedMetrics()
        let motion = motionItems(items)
        let frame = screen.frame
        let vertical = position != .bottom
        let available = (vertical ? frame.height : frame.width) - 24
        let length = min(available, max(90, DockMotionLayout.baseLength(items: motion, metrics: metrics)
                                      + (metrics.maximumIconSize - metrics.iconSize) * 5.2))
        let thickness = metrics.maximumIconSize + metrics.edgeInset + 13
        switch position {
        case .bottom: targetFrame = CGRect(x: frame.midX - length / 2, y: frame.minY, width: length, height: thickness)
        case .left: targetFrame = CGRect(x: frame.minX, y: frame.midY - length / 2, width: thickness, height: length)
        case .right: targetFrame = CGRect(x: frame.maxX - thickness, y: frame.midY - length / 2, width: thickness, height: length)
        }
        if snap || presentedFrame.isEmpty { presentedFrame = targetFrame }
        applyWindowFrame()
        notifyGeometryChanged()
        if let link = frameDisplayLink, frameDisplayID != screenID(screen) {
            let wasRunning = !link.isPaused
            stopFrames()
            if wasRunning { startFrames() }
        }
    }

    private func notifyGeometryChanged() {
        let current = reservedArea
        guard previousReservedArea != current else { return }
        previousReservedArea = current
        onGeometryChanged?()
    }

    private func motionItems(_ items: [DockDisplayItem]) -> [DockMotionItem] {
        var previousRegion: Int?
        return items.map { item in
            let region: Int
            switch item.section {
            // 原生 Dock（显示最近使用时）把没固定的运行中 App 放在分隔线右侧，和最近使用同区。
            case .applications: region = 0
            case .running, .recent: region = 1
            case .files: region = 2
            }
            defer { previousRegion = region }
            return DockMotionItem(id: item.id,
                                  canMerge: !item.id.hasPrefix("system:") && !item.id.hasPrefix("file:") && item.id != DockMotionSurface.finderID,
                                  separatorBefore: previousRegion != nil && previousRegion != region)
        }
    }

    private func makePanel() {
        let panel = DockMotionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "DockApex · 应用栏"
        panel.setAccessibilityTitle(panel.title)
        // 影子模式下系统 Dock 与补底位于 Dock 层及其上一层，应用栏始终在两者之上。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let surface = DockMotionSurface()
        surface.onOpen = { [weak self] id, point in
            if let item = self?.items.first(where: { $0.id == id }), item.isGroup || (id.hasPrefix("file:") && item.acceptsFileDrops) { self?.surface?.retainGroupAnchor(id) }
            self?.onOpen(id, point)
        }
        surface.onMerge = { [weak self] source, target in self?.onMerge(source, target) }
        surface.onReorder = { [weak self] source, index in self?.onReorder(source, index) }
        surface.onRemove = { [weak self] id in self?.onRemove(id) }
        surface.onExternalDrop = { [weak self] drop in self?.onExternalDrop(drop) }
        surface.onContext = { [weak self] id in self?.onContext(id) ?? NSMenu() }
        surface.onHint = { [weak self] text, anchor in self?.showHint(text, anchor: anchor) }
        surface.onHold = { [weak self] reason, active in self?.setInteractionHold(reason, active: active) }
        surface.onNeedsFrames = { [weak self] in self?.startFrames() }
        surface.onDragState = { [weak self] internalDrag, active in self?.dragState(internalDrag: internalDrag, active: active) }
        panel.contentView = surface
        self.panel = panel; self.surface = surface
    }

    private func dragState(internalDrag: Bool, active: Bool) {
        if active {
            setInteractionHold("drag", active: true)
            if internalDrag { pointerCapture = true; captureKeyboard() }
        } else {
            pointerCapture = false
            releaseKeyboard()
            setInteractionHold("drag", active: false)
            let generation = showGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.showGeneration == generation, let pending = self.pendingShow else { return }
                self.pendingShow = nil
                self.show(items: pending.items, position: pending.position, autoHide: pending.autoHide, appearance: pending.appearance)
            }
        }
    }

    /// 栏内拖动期间接收按键（Esc 取消拖动）。
    private func captureKeyboard() {
        guard let panel, let surface else { return }
        panel.permitsKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(surface)
        onFocus(true)
    }

    private func releaseKeyboard() {
        panel?.resignKey()
        panel?.permitsKey = false
        onFocus(false)
    }

    /// 事件的全局屏幕坐标（AppKit 左下原点）。补底等无 window 引用的本应用窗口，locationInWindow 是窗口内坐标，不能直接当屏幕坐标。
    nonisolated private static func screenPoint(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location {
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            return CGPoint(x: location.x, y: primaryHeight - location.y)
        }
        return NSEvent.mouseLocation
    }

    private func installObservers() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown
                let point = Self.screenPoint(of: event)
                let timestamp = event.timestamp
                Task { @MainActor [weak self] in self?.recordPointer(point, timestamp: timestamp); self?.pointerUpdated(isClick: isClick) }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    let point = Self.screenPoint(of: event)
                    self?.recordPointer(point, timestamp: event.timestamp)
                    self?.pointerUpdated(isClick: event.type == .leftMouseDown || event.type == .rightMouseDown)
                }
                return event
            }
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.chooseValidScreen(); self.updateGeometry(snap: true)
                    self.surface?.update(items: self.items, position: self.position, metrics: self.fittedMetrics(), appearance: self.appearance)
                }
            }
        }
        if workspaceObservers.isEmpty {
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.enabled else { return }
                        self.chooseValidScreen(); self.updateGeometry(snap: true)
                        self.surface?.update(items: self.items, position: self.position, metrics: self.fittedMetrics(), appearance: self.appearance)
                        if self.wantsVisible { self.startFrames() }
                    }
                })
            }
        }
        if pollTimer == nil {
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerUpdated(isClick: false) }
            }
            timer.tolerance = 0.025
            pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func pointerUpdated(isClick: Bool) {
        guard enabled else { return }
        let point = currentPointer
        let pointerChanged = lastPointer.map { hypot(point.x - $0.x, point.y - $0.y) > 0.2 } ?? true
        lastPointer = point
        let time = now
        let inside = surface?.containsScreenPoint(point) == true
        if inside != isHovering { isHovering = inside; onPresentationChanged?(isPresented) }
        let near = targetFrame.insetBy(dx: -160, dy: -160).contains(point)
        if near != isNear { isNear = near; onPresentationChanged?(isPresented) }
        if !holds.isEmpty { hideDeadline = nil }
        else if inside, exposure > 0.2 { hideDeadline = nil }
        else if autoHide, wantsVisible { hideDeadline = hideDeadline ?? time + appearance.hideDelay }
        let edgeScreen = eligibleScreens.first { DockMotionLayout.isAtEdge(point, screen: $0.frame, position: position) }
        if let edgeScreen {
            let id = screenID(edgeScreen)
            if screen.map(screenID) != id, surface?.isDragging != true, holds.isEmpty {
                if pendingScreen?.id != id { pendingScreen = (id, time) }
                if let pendingScreen, time - pendingScreen.since >= 0.35 {
                    screen = edgeScreen; updateGeometry(snap: true)
                    applyFullscreenPolicy()
                    surface?.update(items: items, position: position, metrics: fittedMetrics(), appearance: appearance)
                    self.pendingScreen = nil; reveal("screen")
                }
            } else {
                pendingScreen = nil
                if autoHide { hideDeadline = nil; if !wantsVisible || exposure < 0.99 { reveal("edge") } }
            }
        } else { pendingScreen = nil }
        if autoHide, holds.isEmpty, let hideDeadline, time >= hideDeadline, !inside {
            wantsVisible = false; self.hideDeadline = nil; hintPanel?.orderOut(nil); startFrames()
        }
        if !autoHide { wantsVisible = true }
        if (exposure > 0.01 || wantsVisible), surface?.needsContinuousFrames == true
            || pointerChanged && (inside || surface?.hasHoverAppearance == true) { startFrames() }
        updateMousePassThrough()
    }

    private func recordPointer(_ point: CGPoint, timestamp: TimeInterval) {
        guard eventPointer == nil || timestamp >= eventPointer!.timestamp else { return }
        eventPointer = (point, NSEvent.mouseLocation, timestamp)
    }

    /// 事件流优先。硬件位置未变化时，不能覆盖远程控制或辅助功能产生的合法事件坐标。
    private var currentPointer: CGPoint {
        if let sweep {
            // 自测扫动：每 1.5 秒从首个图标扫到最后一个再扫回，不移动真实鼠标。
            let phase = ((now - sweep.started) / 1.5).truncatingRemainder(dividingBy: 2)
            let t = CGFloat(phase <= 1 ? phase : 2 - phase)
            return CGPoint(x: sweep.from.x + (sweep.to.x - sweep.from.x) * t, y: sweep.from.y + (sweep.to.y - sweep.from.y) * t)
        }
        let hardware = NSEvent.mouseLocation
        guard let eventPointer else { return hardware }
        if hypot(hardware.x - eventPointer.hardware.x, hardware.y - eventPointer.hardware.y) > 0.5 { return hardware }
        return eventPointer.point
    }

    private var revealLog: [String] = []
    private func reveal(_ reason: String = "") {
        guard enabled else { return }
        if exposure < 0.5 { revealLog.append(String(format: "%.1f %@ cur%@ hw%@ ev%@", now, reason, NSStringFromPoint(currentPointer), NSStringFromPoint(NSEvent.mouseLocation), eventPointer.map { NSStringFromPoint($0.point) } ?? "-")); if revealLog.count > 12 { revealLog.removeFirst() } }
        hideDeadline = nil
        wantsVisible = true
        if exposure <= 0.01 { panel?.orderFrontRegardless() }
        startFrames()
    }

    @discardableResult
    func updateReferenceDrag(at point: CGPoint?) -> Bool { surface?.updateReferenceDrag(at: point) ?? false }
    func dropReference(_ url: URL, at point: CGPoint) -> Bool { surface?.dropReference(url, at: point) ?? false }

    /// 指针在系统 Dock 图标区移动时，移动事件被拦截、系统报告的指针位置停在原处；
    /// 由拦截线程把真实位置当作一次事件记下，每帧按它放大。
    func pointerNudged(at point: CGPoint) {
        recordPointer(point, timestamp: ProcessInfo.processInfo.systemUptime)
        pointerUpdated(isClick: false)
    }

    /// 自测：虚拟指针沿栏来回扫动 `duration` 秒，期间清零并重新统计帧时序；真实鼠标不动。
    func runSweepBenchmark(duration: TimeInterval) {
        guard enabled, let first = items.first, let last = items.last,
              let from = surface?.screenRect(for: first.id), let to = surface?.screenRect(for: last.id) else { return }
        frameCadence.reset()
        sweep = (now, duration, CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY))
        pointerUpdated(isClick: false)
        startFrames()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            self.sweep = nil
            self.pointerUpdated(isClick: false)
        }
    }

    /// 回调本身只是一帧的一部分；在主线程进入等待前记下整帧耗时（含布局、绘制与 Core Animation 提交）。
    private func installBusyObserver() {
        guard busyObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.frameStartedAt else { return }
                self.frameStartedAt = nil
                self.frameCadence.recordBusy(self.now - started)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        busyObserver = observer
    }

    private func startFrames() {
        guard enabled, let screen else { return }
        installBusyObserver()
        let id = screenID(screen)
        if let link = frameDisplayLink, frameDisplayID == id {
            // 同一块屏只恢复已挂起的计时器，不反复销毁重建。
            if link.isPaused {
                lastFrameTime = now; frameStartedAt = nil
                // 面板层级高于普通窗口，已在屏上就不用重排；每次重排都要同步等 WindowServer，忙时卡几十到几百毫秒。
                if wantsVisible, let panel, !panel.isVisible { panel.orderFrontRegardless() }
                link.isPaused = false
            }
            return
        }
        stopFrames()
        lastFrameTime = now
        // 屏幕同步调度也能驱动完全藏到边缘外的面板；随当前屏幕迁移重建。
        let link = screen.displayLink(target: self, selector: #selector(displayFrame(_:)))
        let maximum = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        frameDisplayLink = link
        frameDisplayID = id
        if wantsVisible, let panel, !panel.isVisible { panel.orderFrontRegardless() }
        link.add(to: .main, forMode: .common)
    }

    /// 画面静止时挂起计时器，保留到下次动起来直接恢复。
    private func pauseFrames() {
        frameStartedAt = nil
        frameDisplayLink?.isPaused = true
        frameCadence.endActiveSegment()
    }

    private func stopFrames() {
        frameStartedAt = nil
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
        frameDisplayID = nil
        frameCadence.endActiveSegment()
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        guard enabled else { stopFrames(); return }
        let callbackStarted = now
        // 上一帧到这一帧之间主线程一直没空下来：整段都算上一帧的忙碌时间。
        if let previous = frameStartedAt { frameCadence.recordBusy(callbackStarted - previous) }
        frameStartedAt = callbackStarted
        let expectedInterval = max(0.001, link.targetTimestamp - link.timestamp)
        let time = link.targetTimestamp > 0 ? link.targetTimestamp : now
        let delta = min(0.05, max(0.001, time - lastFrameTime)); lastFrameTime = time
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fraction: CGFloat = reduce ? 1 : CGFloat(1 - exp(-delta / 0.055))
        presentedFrame = DockMotionLayout.interpolated(presentedFrame, toward: targetFrame, fraction: fraction)
        if rectDelta(presentedFrame, targetFrame) < 0.08 { presentedFrame = targetFrame }
        let goal: CGFloat = wantsVisible || !holds.isEmpty || !autoHide ? 1 : 0
        exposure += (goal - exposure) * (reduce ? 1 : CGFloat(1 - exp(-delta / 0.055)))
        if abs(exposure - goal) < 0.003 { exposure = goal }
        applyWindowFrame()
        if (exposure > 0.01) != isPresented { isPresented = exposure > 0.01; onPresentationChanged?(isPresented) }
        let pointer = currentPointer
        if lastFramePointer.map({ hypot(pointer.x - $0.x, pointer.y - $0.y) > 0.2 }) ?? true { lastPointerMotion = callbackStarted }
        lastFramePointer = pointer
        let moving = surface?.advance(time: time, delta: delta, pointer: pointer) ?? false
        updateMousePassThrough()
        frameCadence.record(at: callbackStarted, expectedInterval: expectedInterval, workDuration: max(0, now - callbackStarted))
        // 指针在栏上移动时，放大布局一帧就对准指针，看起来“已静止”；此时仍要按屏幕刷新率连续出帧，
        // 否则画面只在鼠标事件到达时才更新，节奏跟着事件走，显得掉帧。指针停住 0.3 秒后再挂起。
        let tracking = callbackStarted - lastPointerMotion < 0.3 && surface?.containsScreenPoint(pointer) == true
        if goal == 0, exposure == 0 {
            panel?.orderOut(nil); hintPanel?.orderOut(nil)
            pauseFrames()
        } else if !moving, !tracking, exposure == goal, presentedFrame == targetFrame {
            pauseFrames()
        }
    }

    private func rectDelta(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    private func updateMousePassThrough() {
        guard let panel else { return }
        let ignoresMouseEvents = !pointerCapture && surface?.isDragging != true
            && !holds.contains("menu") && surface?.containsScreenPoint(currentPointer) != true
        // AppKit 的 setter 即使值相同也会修改 WindowServer tags 并提交事务；只在命中状态真正改变时更新。
        if panel.ignoresMouseEvents != ignoresMouseEvents { panel.ignoresMouseEvents = ignoresMouseEvents }
    }

    private func applyWindowFrame() {
        guard let panel, !presentedFrame.isEmpty else { return }
        var frame = presentedFrame
        let offset = (position == .bottom ? frame.height + 8 : frame.width + 8) * (1 - exposure)
        switch position {
        case .bottom: frame.origin.y -= offset
        case .left: frame.origin.x -= offset
        case .right: frame.origin.x += offset
        }
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if let screen { surface?.setScreenClip(frame.intersection(screen.frame).offsetBy(dx: -frame.minX, dy: -frame.minY)) }
    }

    /// 预建名称提示的玻璃胶囊，避免第一次悬停时在主线程现建窗口和材质。
    /// 提示窗口是一条固定在应用栏上方的透明条，胶囊在条内移动：放大时图标逐帧移动，
    /// 若移动窗口本身，每帧都要同步重排玻璃并与 WindowServer 往返一次，是悬停掉帧的主要来源。
    private func ensureHintPanel() {
        guard hintPanel == nil else { return }
        let (panel, label) = HintBubbleView.makePanel(title: "DockApex · 操作提示")
        let bubble = panel.contentView as? HintBubbleView
        let strip = NSView()
        strip.wantsLayer = true
        panel.contentView = strip
        if let bubble { strip.addSubview(bubble) }
        hintPanel = panel; hintLabel = label; hintBubble = bubble
    }

    /// 覆盖应用栏及其上方一段；只在应用栏位置或尺寸变化时移动。
    private func hintStripFrame(containing bubble: CGRect) -> CGRect {
        let bar = targetFrame
        var strip: CGRect
        switch position {
        case .bottom: strip = CGRect(x: bar.minX - 240, y: bar.minY, width: bar.width + 480, height: bar.height + 60)
        case .left: strip = CGRect(x: bar.minX, y: bar.minY - 60, width: bar.width + 400, height: bar.height + 120)
        case .right: strip = CGRect(x: bar.minX - 400, y: bar.minY - 60, width: bar.width + 400, height: bar.height + 120)
        }
        if let screen { strip = strip.intersection(screen.frame) }
        return strip.contains(bubble) ? strip : strip.union(bubble)
    }

    /// 窗口预览出现时收起名称提示（预览里已有窗口标题）。
    func hideNameHint() {
        if hintPanel?.isVisible == true { hintPanel?.orderOut(nil) }
        lastHint = nil
    }

    private func showHint(_ text: String?, anchor: CGRect) {
        guard !suppressesHint, !WindowPreviewController.shared.isShown, let text, exposure > 0.9 else {
            if hintPanel?.isVisible == true { hintPanel?.orderOut(nil) }
            lastHint = nil
            return
        }
        ensureHintPanel()
        guard let hintPanel, let hintLabel, let hintBubble else { return }
        if hintLabel.stringValue != text { hintLabel.stringValue = text }
        let safe = screen?.visibleFrame ?? CGRect(origin: .zero, size: CGSize(width: 1440, height: 900))
        let key = HintMeasurementKey(text: text, font: hintLabel.font, appearance: hintLabel.effectiveAppearance.name,
                                     displayID: screen.map(screenID), screenFrame: screen?.frame,
                                     safeFrame: safe, backingScale: screen?.backingScaleFactor)
        let size: CGSize
        if let hintMeasurement, hintMeasurement.key == key {
            size = hintMeasurement.size
        } else {
            // 文本、外观或显示环境变化才重新测量；图标逐帧移动只调整提示位置。
            size = CGSize(width: min(360, ceil(hintLabel.fittingSize.width) + 26), height: HintBubbleView.bodyHeight + HintBubbleView.tailHeight)
            hintMeasurement = (key, size)
        }
        var origin: CGPoint
        switch position {
        case .bottom: origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 5.5)
        case .left: origin = CGPoint(x: anchor.maxX + 12, y: anchor.midY - size.height / 2)
        case .right: origin = CGPoint(x: anchor.minX - size.width - 12, y: anchor.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, safe.minX + 5), safe.maxX - size.width - 5)
        origin.y = min(max(origin.y, safe.minY + 5), safe.maxY - size.height - 5)
        let frame = CGRect(origin: origin, size: size)
        let isVisible = hintPanel.isVisible
        if lastHint?.text == text, lastHint?.frame == frame, isVisible { return }
        let strip = hintStripFrame(containing: frame)
        if hintStrip != strip { hintStrip = strip; hintPanel.setFrame(strip, display: false) }
        let local = CGRect(x: frame.minX - strip.minX, y: frame.minY - strip.minY, width: frame.width, height: frame.height)
        // 只移动位置时不改尺寸，胶囊不重排；尺寸变化（换了名称）才整体设置。
        if hintBubble.frame.size != local.size { hintBubble.frame = local }
        else if hintBubble.frame.origin != local.origin { hintBubble.setFrameOrigin(local.origin) }
        hintBubble.tailX = position == .bottom ? (anchor.midX - frame.minX).rounded() : nil
        lastHint = (text, frame)
        if !isVisible { hintPanel.orderFrontRegardless() }
    }
}

@MainActor
private final class DockMotionPanel: NSPanel {
    var permitsKey = false
    override var canBecomeKey: Bool { permitsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DockMotionSurface: NSView, NSMenuDelegate {
    static let finderID = "app:/System/Library/CoreServices/Finder.app"
    var onOpen: ((String, CGPoint) -> Void)?
    var onMerge: ((String, String) -> Void)?
    var onReorder: ((String, Int) -> Void)?
    var onRemove: ((String) -> Void)?
    var onExternalDrop: ((DockExternalDrop) -> Void)?
    var onContext: ((String) -> NSMenu)?
    var onHint: ((String?, CGRect) -> Void)?
    var onHold: ((String, Bool) -> Void)?
    var onNeedsFrames: (() -> Void)?
    var onDragState: ((Bool, Bool) -> Void)?
    private(set) var isDragging = false
    private var items: [DockDisplayItem] = []
    private var icons: [String: DockMotionIcon] = [:]
    private var motion: [DockMotionItem] = []
    private var metrics = DockMotionMetrics()
    private var visualSettings = DockBarAppearance.nativeDefaults
    private var position = DockPosition.bottom
    private var presented: [String: CGRect] = [:]
    private var layoutFrames: [String: CGRect] = [:]
    private var lastClip = CGRect.null
    private var backdropRect = CGRect.zero
    private var separators: [CGRect] = []
    private var placeholder: CGRect?
    private var backdrop: NSView!
    private let overlay = DockMotionOverlay()
    private var pointer = CGPoint.zero
    private var hotID: String?
    private var reportedHover: String?
    private var activeGroupID: String?
    private var activeGroupSnapshot: DockMotionSnapshot?
    /// 静止布局按哪个尺寸算的。应用栏窗口随条目增减逐帧改尺寸，旧尺寸里算出的位置会让图标偏离面板。
    private var activeGroupBounds = CGRect.zero
    private var pressedID: String?
    private var pressedPointer: CGPoint?
    private var magnifyAmount: CGFloat = 0
    private var lastMagnificationPointer: CGPoint?
    private var sourceID: String?
    private var grabOffset = CGPoint.zero
    private var dragPoint = CGPoint.zero
    private var dragGap: Int?
    private var dragSize: CGFloat = 37
    private var dragStarted: TimeInterval = 0
    private var lastDragEvent: TimeInterval = 0
    private var hardwareDragObservedDown = false
    private var outsideForRemoval = false
    private var mergeIntent = DockMergeIntent()
    private var externalDrag = false
    /// 每次外部拖入记一条：数据类型与来源允许的操作（不记文件名），用于排查拖不进来的来源。由应用控制器设置。
    static var logDrop: ((String) -> Void)?
    private var loggedDragSequence: Int?
    private var externalApps = true
    private var externalTargetID: String?
    private var ghostPanel: NSPanel?
    private var ghostView: DockMotionGhost?
    private var launching: [String: TimeInterval] = [:]
    private var observedMenu: NSMenu?
    private weak var forwardedMenuDelegate: NSMenuDelegate?
    private var menuID: String?
    private var menuSnapshot: DockMotionSnapshot?
    private var menuClosedAt: TimeInterval?
    private var dragSizes: [String: CGFloat] = [:]
    private var mergeSnapshot: DockMotionSnapshot?
    private var overlayState = DockMotionOverlayState()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            // 圆角对齐原生 Dock：10-23 同一壁纸下截图拟合原生约 13.4 点（原先 15 点偏圆）。
            let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 13
            glass.contentView = NSView()
            // 不开交互玻璃：实测悬停放大扫动时它让每帧多出约 3ms 的玻璃重排，120Hz 下明显掉帧。
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = 13; effect.layer?.masksToBounds = true
            backdrop = effect
        }
        backdrop.setAccessibilityElement(false)
        addSubview(backdrop)
        overlay.autoresizingMask = [.width, .height]
        overlay.setAccessibilityElement(false)
        addSubview(overlay)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true); setAccessibilityRole(.toolbar)
        setAccessibilityLabel("应用栏，支持放大、排序和拖叠分组")
        setAccessibilityIdentifier("dockfolders.application-bar")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func update(items: [DockDisplayItem], position: DockPosition, metrics: DockMotionMetrics, appearance: DockBarAppearance) {
        self.items = items; self.position = position; self.metrics = metrics; self.visualSettings = appearance
        var priorRegion: Int?
        motion = items.map { item in
            let region: Int
            switch item.section { case .applications: region = 0; case .running, .recent: region = 1; case .files: region = 2 }
            defer { priorRegion = region }
            return DockMotionItem(id: item.id, canMerge: canMove(item.id) && !item.id.hasPrefix("file:"), separatorBefore: priorRegion != nil && priorRegion != region)
        }
        let ids = Set(items.map(\.id))
        for (id, view) in icons where !ids.contains(id) { view.removeFromSuperview(); icons.removeValue(forKey: id); presented.removeValue(forKey: id); layoutFrames.removeValue(forKey: id) }
        for item in items {
            if let existing = icons[item.id] { existing.update(item) }
            else { let icon = DockMotionIcon(item: item); icon.surface = self; addSubview(icon); icons[item.id] = icon }
            if item.isRunning { launching.removeValue(forKey: item.id) }
        }
        setAccessibilityChildren(items.compactMap { icons[$0.id] })
        // 展开期间条目变化（如有应用启动）时，按新条目重算静止布局，面板仍对准文件夹。
        if activeGroupID != nil, activeGroupSnapshot != nil { lockRestingLayout() }
        if presented.isEmpty { installSnapshot(pointer: nil, fraction: 1, time: ProcessInfo.processInfo.systemUptime) }
        if overlay.frame != bounds { overlay.frame = bounds }
        updateOverlay()
    }

    func updateRuntime(_ items: [DockDisplayItem]) {
        let runtime = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.items = self.items.map { runtime[$0.id] ?? $0 }
        for item in items { icons[item.id]?.update(item) }
        updateOverlay()
    }

    private func canMove(_ id: String) -> Bool { !id.hasPrefix("system:") && id != Self.finderID }
    private var localPointer: CGPoint {
        pointer
    }

    /// 窗口预览的弹出位置：与右键菜单一样从图标外侧弹出（底部 Dock 时在上方），箭头指向此刻图标的位置。
    /// 应用栏窗口按最大放大量定长、不随放大变化，预览挂在栏上不会跟着放大回落横移。
    func previewAnchor(for id: String) -> WindowPreviewController.Anchor? {
        guard let frame = presented[id] else { return nil }
        switch position {
        case .bottom: return .init(view: self, rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + 3), edge: .maxY)
        case .left: return .init(view: self, rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width + 3, height: frame.height), edge: .maxX)
        case .right: return .init(view: self, rect: CGRect(x: frame.minX - 3, y: frame.minY, width: frame.width + 3, height: frame.height), edge: .minX)
        }
    }

    func screenRect(for id: String) -> CGRect? {
        guard let rect = (activeGroupID == id ? activeGroupSnapshot?.frames[id] : nil) ?? presented[id], let window else { return nil }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func restingScreenRect(for id: String) -> CGRect? {
        guard let window else { return nil }
        var restingMetrics = metrics; restingMetrics.magnification = false
        let resting = DockMotionLayout.snapshot(items: motion, in: bounds, position: position, metrics: restingMetrics, pointer: nil)
        guard let rect = resting.frames[id] else { return nil }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let iconsUnion = presented.filter { $0.key != sourceID }.values.reduce(CGRect.null) { $0.union($1) }
        return backdropRect.insetBy(dx: -6, dy: -5).contains(local)
            || !iconsUnion.isNull && iconsUnion.insetBy(dx: -4, dy: -4).contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if let id = DockMotionLayout.hitTest(point, frames: presented, orderedIDs: items.map(\.id)), let icon = icons[id] { return icon }
        return backdropRect.contains(point) ? self : nil
    }

    var needsContinuousFrames: Bool { observedMenu == nil && (isDragging || !launching.isEmpty) }
    var interactionSummary: [String: Any] {
        ["hot": hotID ?? "",
         "pressed": pressedID ?? "", "activeGroup": activeGroupID ?? "", "menuOpen": observedMenu != nil,
         "retainedSnapshot": menuSnapshot != nil || mergeSnapshot != nil || activeGroupSnapshot != nil, "dragging": isDragging]
    }
    var hasHoverAppearance: Bool { hotID != nil || activeGroupID != nil }

    func setScreenClip(_ rect: CGRect) {
        guard rect != lastClip else { return }
        lastClip = rect
        if layer?.mask == nil { layer?.mask = CAShapeLayer() }
        if let mask = layer?.mask as? CAShapeLayer {
            mask.frame = bounds
            mask.path = CGPath(rect: rect.isNull || rect.isEmpty ? .zero : rect, transform: nil)
        }
    }

    func advance(time: TimeInterval, delta: TimeInterval, pointer screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        launching = launching.filter { time < $0.value }
        pointer = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        // 状态自愈：按键已松开、菜单未真正打开时，不能让旧状态冻结放大和提示。
        if pressedPointer != nil, sourceID == nil, NSEvent.pressedMouseButtons & 0b11 == 0 { pressedID = nil; pressedPointer = nil }
        // targetTimestamp 可指向下一显示帧，只能驱动画面插值；拖叠按真实时间算指针速度。
        let interactionTime = ProcessInfo.processInfo.systemUptime
        if sourceID != nil {
            dragPoint = pointer
            updateIntent(at: pointer, time: interactionTime)
            moveGhost(screenPoint)
            if NSEvent.pressedMouseButtons & 1 != 0 { hardwareDragObservedDown = true }
            else if hardwareDragObservedDown, interactionTime - lastDragEvent > 0.08 { finishDrag(at: pointer, cancelled: false) }
        } else if externalDrag { updateIntent(at: dragPoint, time: interactionTime) }
        let inside = containsScreenPoint(screenPoint)
        let hot = activeGroupID ?? (inside ? DockMotionLayout.hitTest(pointer, frames: presented, orderedIDs: items.map(\.id), expansion: 5) : nil)
        hotID = hot
        let hovered = isDragging || observedMenu != nil || activeGroupID != nil ? nil : hot
        if hovered != reportedHover { reportedHover = hovered; Self.onHoverChanged?(hovered) }
        var magnificationPointer: CGPoint?
        if !isDragging {
            if let pressedPointer { magnificationPointer = pressedPointer }
            else if inside { magnificationPointer = pointer }
        }
        // 原生实测：栏内位置立即跟手；放大程度在移入时约 120ms、移出时约 110ms 内缓入缓出。
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // 分组展开期间布局锁定在未放大的静止快照：放大量同步回落，收起后再从未放大缓入，两头都不硬切。
        let groupSettling = activeGroupSnapshot != nil && !isDragging
        let target: CGFloat = magnificationPointer != nil && !groupSettling ? 1 : 0
        if let magnificationPointer { lastMagnificationPointer = magnificationPointer }
        // 菜单开着时放大量与布局一起冻结。否则指针移到菜单上时放大量照常衰减，关菜单那一帧布局按衰减后的放大量重算，
        // 图标先猛地缩小再长回来，看起来一闪（10-23 逐帧实测关菜单一帧内 62 → 57 点）。
        if menuSnapshot != nil {}
        else if reduce { magnifyAmount = target }
        else if target > magnifyAmount { magnifyAmount = min(1, magnifyAmount + CGFloat(delta / 0.12)) }
        else if target < magnifyAmount { magnifyAmount = max(0, magnifyAmount - CGFloat(delta / 0.11)) }
        let eased = magnifyAmount * magnifyAmount * (3 - 2 * magnifyAmount)
        var effective = metrics
        effective.maximumIconSize = metrics.iconSize + (metrics.maximumIconSize - metrics.iconSize) * eased
        let magnifying = magnifyAmount > 0 && !isDragging
        // 关菜单后约 0.2 秒内从冻结的布局缓到当前目标（与指针移出栏时同样的缓动），不在一帧里跳过去；之后恢复放大即时跟手。
        let easingOutOfMenu = menuClosedAt.map { interactionTime - $0 < 0.2 } ?? false
        if !easingOutOfMenu { menuClosedAt = nil }
        let fraction: CGFloat = reduce || (!easingOutOfMenu && !groupSettling && (magnifying || target == 1)) ? 1 : CGFloat(1 - exp(-delta / 0.045))
        let geometryMoving = installSnapshot(pointer: magnifying ? lastMagnificationPointer : nil, fraction: fraction, time: time,
                                             metrics: magnifying ? effective : metrics)
            || (magnifyAmount > 0 && magnifyAmount < 1)
        for (id, view) in icons {
            // 分组展开后角标已显示在组内成员上，栏上的分组角标先隐去。
            view.badgeSuppressed = id == activeGroupID
            if mergeCommit?.target == id { view.setMerge(.landing) }
            else if mergeIntent.target == id { view.setMerge(.armed) }
            else { view.setMerge(.none) }
        }
        if isDragging {
            if panelDropTarget != nil {
                onHint?("松开加入分组", CGRect(x: screenPoint.x - 1, y: screenPoint.y + 30, width: 2, height: 2))
            } else if outsideForRemoval { onHint?("松开移出应用栏", screenRect(for: sourceID ?? "") ?? window.frame) }
            else if externalDrag, let targetID = externalTargetID, let item = items.first(where: { $0.id == targetID }),
                    !externalApps || isFileOperationTarget(targetID), let rect = screenRect(for: targetID) {
                onHint?(isFileOperationTarget(targetID) ? "松开移到“\(item.name)”" : "松开用“\(item.name)”打开", rect)
            }
            // 拖到目标中央即长出文件夹底板并出这一条提示。
            else if let id = mergeIntent.target, let item = items.first(where: { $0.id == id }), let rect = screenRect(for: id) {
                onHint?(item.isGroup ? "松开加入分组" : "松开创建分组", rect)
            } else { onHint?(nil, .zero) }
        } else if observedMenu == nil, let hot, let item = items.first(where: { $0.id == hot }), let rect = screenRect(for: hot) {
            onHint?(item.name, rect)
        } else { onHint?(nil, .zero) }
        return geometryMoving || needsContinuousFrames
    }

    @discardableResult
    private func installSnapshot(pointer: CGPoint?, fraction: CGFloat, time: TimeInterval, metrics override: DockMotionMetrics? = nil) -> Bool {
        if activeGroupSnapshot != nil, activeGroupBounds != bounds { lockRestingLayout() }
        let retained = menuSnapshot ?? mergeSnapshot ?? (isDragging ? nil : activeGroupSnapshot)
        let snapshot = DockMotionLayout.snapshot(
            items: motion, in: bounds, position: position, metrics: override ?? metrics,
            pointer: pointer, retainedSnapshot: retained,
            draggedID: sourceID, insertionGap: dragGap, preservedSizes: dragSizes)
        // 菜单与合并快照需原地冻结；分组展开快照平滑回到静止布局。
        let layoutFraction: CGFloat = retained == nil || (menuSnapshot == nil && mergeSnapshot == nil) ? fraction : 1
        var moving = false
        backdropRect = backdropRect.isEmpty ? snapshot.background : DockMotionLayout.interpolated(backdropRect, toward: snapshot.background, fraction: layoutFraction)
        if frameDistance(backdropRect, snapshot.background) < 0.08 { backdropRect = snapshot.background } else { moving = true }
        if backdrop.frame != backdropRect { backdrop.frame = backdropRect }
        separators = snapshot.separators
        placeholder = snapshot.placeholder
        for (id, rect) in snapshot.frames {
            var baseFrame = DockMotionLayout.interpolated(layoutFrames[id] ?? rect, toward: rect, fraction: layoutFraction)
            if frameDistance(baseFrame, rect) < 0.08 { baseFrame = rect } else { moving = true }
            layoutFrames[id] = baseFrame
            var frame = baseFrame
            if retained == nil, let until = launching[id], time < until, visualSettings.animateLaunching, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let phase = (until - time) * 8
                let lift = abs(sin(phase)) * min(12, metrics.iconSize * 0.25)
                switch position { case .bottom: frame.origin.y += lift; case .left: frame.origin.x += lift; case .right: frame.origin.x -= lift }
            }
            presented[id] = frame
            if let icon = icons[id], icon.frame != frame { icon.frame = frame }
        }
        if let sourceID, let source = icons[sourceID], source.alphaValue != 0 { source.alphaValue = 0 }
        if overlay.frame != bounds { overlay.frame = bounds }
        updateOverlay()
        return moving
    }

    private func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    func open(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), let rect = screenRect(for: id) else { return }
        if item.isGroup || (id.hasPrefix("file:") && item.acceptsFileDrops) { activeGroupID = id }
        if !item.isRunning, !item.isGroup, id.hasPrefix("app:"), visualSettings.animateLaunching { launching[id] = ProcessInfo.processInfo.systemUptime + 1.2 }
        onNeedsFrames?()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        onOpen?(id, CGPoint(x: rect.midX, y: primaryHeight - rect.midY))
    }

    func releaseActiveGroup() { activeGroupID = nil; activeGroupSnapshot = nil; onNeedsFrames?() }
    /// 展开期间锁定为未放大的静止布局：文件夹图标回到正常尺寸，面板对准静止位置。
    func retainGroupAnchor(_ id: String) {
        activeGroupID = id
        lockRestingLayout()
        layoutFrames = presented
        onNeedsFrames?()
    }
    private func lockRestingLayout() {
        activeGroupSnapshot = DockMotionLayout.snapshot(items: motion, in: bounds, position: position, metrics: metrics, pointer: nil)
        activeGroupBounds = bounds
    }
    func press(_ id: String, point: CGPoint) { pressedID = id; pressedPointer = point; onNeedsFrames?() }
    func releasePress() { pressedID = nil; pressedPointer = nil; onNeedsFrames?() }

    /// 只在栏内拖动期间收到按键：Esc 取消拖动。
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isDragging else { super.keyDown(with: event); return }
        cancelInteraction()
        onNeedsFrames?()
    }

    func beginDrag(_ icon: DockMotionIcon, event: NSEvent, originalPoint: CGPoint, originalFrame: CGRect) {
        guard sourceID == nil, canMove(icon.item.id), presented[icon.item.id] != nil, let window else { return }
        dragSizes = layoutFrames.mapValues(\.width)
        mergeSnapshot = nil
        sourceID = icon.item.id; isDragging = true; externalDrag = false
        dragGap = items.firstIndex(where: { $0.id == icon.item.id }) ?? 0
        dragSize = originalFrame.width; dragStarted = ProcessInfo.processInfo.systemUptime
        lastDragEvent = dragStarted
        hardwareDragObservedDown = NSEvent.pressedMouseButtons & 1 != 0
        grabOffset = CGPoint(x: originalPoint.x - originalFrame.minX, y: originalPoint.y - originalFrame.minY)
        releasePress()
        dragPoint = convert(event.locationInWindow, from: nil)
        mergeIntent.reset(); outsideForRemoval = false
        makeGhost(icon.item.icon)
        onDragState?(true, true)
        moveGhost(window.convertPoint(toScreen: event.locationInWindow))
        updateIntent(at: dragPoint, time: dragStarted)
    }

    func moveDrag(_ event: NSEvent) {
        guard sourceID != nil, let window else { return }
        lastDragEvent = ProcessInfo.processInfo.systemUptime
        dragPoint = convert(event.locationInWindow, from: nil)
        updateIntent(at: dragPoint, time: ProcessInfo.processInfo.systemUptime)
        moveGhost(window.convertPoint(toScreen: event.locationInWindow))
    }

    private func updateIntent(at point: CGPoint, time: TimeInterval) {
        dragPoint = point
        // 分组面板展开时，把应用拖到面板上即加入该分组；面板在栏上方，不能按“拖离栏”当作移出。
        if let sourceID, sourceID.hasPrefix("app:"), let window, let target = Self.openGroupTarget?() {
            let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
            if target.frame.contains(screenPoint) {
                panelDropTarget = target.id
                outsideForRemoval = false
                mergeIntent.reset(); mergeSnapshot = nil
                Self.previewGroupIncoming?(screenPoint)
                return
            }
        }
        if panelDropTarget != nil { panelDropTarget = nil; Self.previewGroupIncoming?(nil) }
        outsideForRemoval = sourceID != nil && DockMotionLayout.distanceOutside(point, rect: backdropRect) >= 80 && time - dragStarted >= 0.25
        let targetFrames = mergeSnapshot?.frames ?? presented
        let target = outsideForRemoval || externalDrag && !externalApps ? nil : DockMotionLayout.mergeTarget(point: point, items: motion, frames: targetFrames, excluding: sourceID, previousCandidate: mergeIntent.target)
        let previousCandidate = mergeIntent.target
        mergeIntent.update(target: target, point: point, time: time)
        if mergeIntent.target == nil { mergeSnapshot = nil }
        else if previousCandidate != mergeIntent.target || mergeSnapshot == nil {
            // 进入目标中央时锁住用户实际看见的目标，避免插入占位继续把目标推走。
            mergeSnapshot = currentSnapshot(excluding: sourceID)
        }
        if mergeIntent.target == nil {
            let candidateGap = DockMotionLayout.insertionGap(point: point, items: motion, frames: presented, position: position, excluding: sourceID)
            let firstFile = items.firstIndex(where: { $0.section == .files }) ?? items.count
            let firstMovable = items.first?.id == Self.finderID ? 1 : 0
            if sourceID.flatMap({ id in items.first(where: { $0.id == id }) })?.section == .files {
                dragGap = max(firstFile, min(items.count, candidateGap))
            } else { dragGap = max(firstMovable, min(firstFile, candidateGap)) }
        }
    }

    func finishDrag(at point: CGPoint, cancelled: Bool) {
        guard let source = sourceID else { return }
        if !cancelled { updateIntent(at: point, time: ProcessInfo.processInfo.systemUptime) }
        let target = mergeIntent.target
        let panelTarget = panelDropTarget
        panelDropTarget = nil
        let gap = dragGap ?? 0
        let remove = outsideForRemoval
        let inside = DockMotionLayout.distanceOutside(point, rect: backdropRect) < 35
        let landing = !cancelled && (panelTarget != nil || (!remove && inside && target != nil))
        sourceID = nil; isDragging = false; outsideForRemoval = false; dragGap = nil
        dragSizes.removeAll()
        mergeIntent.reset()
        if !landing {
            mergeSnapshot = nil
            ghostPanel?.orderOut(nil)
            icons[source]?.alphaValue = 1
        }
        onHint?(nil, .zero)
        onDragState?(true, false)
        onNeedsFrames?()
        guard !cancelled else {
            if panelTarget != nil { Self.previewGroupIncoming?(nil) }
            return
        }
        if let panelTarget { landInGroupPanel(source: source, target: panelTarget) }
        else if remove { onRemove?(source) }
        else if landing, let target { landMerge(source: source, target: target) }
        else if inside { onReorder?(source, gap) }
    }

    /// 拖进展开的分组面板：拖动图标飞进面板让出的空位，到位后再加入分组，新成员就出现在这个位置。
    private func landInGroupPanel(source: String, target: String) {
        guard let ghostPanel, ghostPanel.isVisible, let landing = Self.groupIncomingLanding?() else {
            ghostPanel?.orderOut(nil); mergeSnapshot = nil
            onMerge?(source, target)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
            ghostPanel.animator().setFrame(landing, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mergeSnapshot = nil
                self.onMerge?(source, target)
                ghostPanel.orderOut(nil)
                self.icons[source]?.alphaValue = 1
                self.onNeedsFrames?()
            }
        })
    }

    /// iPhone 式落入：拖动图标边缩小边飞进目标的空格，到位后再真正合并，新分组图标与动画终点重合。
    /// 飞行期间布局保持进入目标时冻结的快照，源图标保持隐藏，避免它先回到原位又被移除。
    private func landMerge(source: String, target: String) {
        guard let icon = icons[target], let ghostPanel, let window, ghostPanel.isVisible else {
            ghostPanel?.orderOut(nil); mergeSnapshot = nil
            onMerge?(source, target)
            return
        }
        mergeCommit = (source, target)
        icon.setMerge(.landing)
        let landing = window.convertToScreen(icon.convert(icon.mergeLandingRect, to: nil))
        let sourceImage = icons[source]?.bitmap
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
            ghostPanel.animator().setFrame(landing, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                icon.landSource(sourceImage)
                ghostPanel.orderOut(nil)
                self.mergeCommit = nil
                self.mergeSnapshot = nil
                self.onMerge?(source, target)
                // 合并成功时源图标已随刷新移除；没合并成（例如不允许分组）时把它显示回来。
                self.icons[source]?.alphaValue = 1
                self.onNeedsFrames?()
            }
        })
    }

    func cancelInteraction() {
        if sourceID != nil { finishDrag(at: localPointer, cancelled: true) }
        else if externalDrag { endExternal() }
    }

    override func cancelOperation(_ sender: Any?) { cancelInteraction() }

    private func makeGhost(_ image: NSImage) {
        if ghostPanel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.hasShadow = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = DockMotionGhost(); panel.contentView = view
            ghostPanel = panel; ghostView = view
        }
        ghostView?.image = image
        ghostPanel?.setContentSize(CGSize(width: dragSize, height: dragSize))
        if window?.isVisible == true { ghostPanel?.orderFrontRegardless() }
    }

    private func moveGhost(_ screenPoint: CGPoint) {
        ghostView?.removing = outsideForRemoval
        ghostPanel?.setFrameOrigin(CGPoint(x: screenPoint.x - grabOffset.x, y: screenPoint.y - grabOffset.y))
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu(id: "system:settings") }
    func makeMenu(id: String) -> NSMenu? {
        let menu = onContext?(id)
        menuID = id
        forwardedMenuDelegate = menu?.delegate
        menu?.delegate = self
        return menu
    }
    /// 悬停的条目变了（nil 为离开或正在拖动、开菜单、展开分组），窗口预览据此弹出。由应用控制器设置。
    static var onHoverChanged: ((String?) -> Void)?
    /// 当前展开的分组面板（分组条目 ID 与面板屏幕坐标）；拖到面板上松开即加入该分组。由应用控制器设置。
    static var openGroupTarget: (() -> (id: String, frame: CGRect)?)?
    /// 拖到展开的分组面板上时，让面板按指针位置让出空位（nil 表示离开面板）。由应用控制器设置。
    static var previewGroupIncoming: ((CGPoint?) -> Void)?
    /// 面板里让出的空位（屏幕坐标），松开时拖动图标飞进这里。
    static var groupIncomingLanding: (() -> CGRect?)?
    private var panelDropTarget: String?
    /// 松开建组后拖动图标正飞入目标格；期间布局保持进入目标时冻结的样子。
    private var mergeCommit: (source: String, target: String)?

    /// 弹出菜单前的异步准备（读取 App 原生 Dock 菜单）；由应用控制器设置。
    static var prepareMenu: ((String, @escaping @MainActor () -> Void) -> Void)?

    func showMenu(for id: String) {
        guard let prepare = Self.prepareMenu else { presentMenu(for: id); return }
        onHold?("menu-prepare", true)
        prepare(id) { [weak self] in
            self?.onHold?("menu-prepare", false)
            self?.presentMenu(for: id)
        }
    }

    /// 与原生 Dock 一致：菜单出现在图标外侧（底部 Dock 时在图标上方），用系统弹出框承载，箭头指向图标。
    /// 含子菜单的菜单（栏空白处的设置）仍用系统菜单，出现在图标上方、左右居中。
    private func presentMenu(for id: String) {
        guard let menu = makeMenu(id: id), let icon = icons[id] else { return }
        let bounds = icon.bounds
        guard !menu.items.contains(where: \.hasSubmenu) else {
            let size = menu.size, gap: CGFloat = 8
            // popUp 的位置是菜单左上角（图标坐标，y 向上）。
            let topLeft: CGPoint
            switch position {
            case .bottom: topLeft = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY + gap + size.height)
            case .left: topLeft = CGPoint(x: bounds.maxX + gap, y: bounds.midY + size.height / 2)
            case .right: topLeft = CGPoint(x: bounds.minX - gap - size.width, y: bounds.midY + size.height / 2)
            }
            menu.popUp(positioning: nil, at: topLeft, in: icon)
            return
        }
        // 箭头尖端落在矩形边上；向外放 3 点，尖端离图标约 3 点。
        let rect: CGRect, edge: NSRectEdge
        switch position {
        case .bottom: rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height + 3); edge = .maxY
        case .left: rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width + 3, height: bounds.height); edge = .maxX
        case .right: rect = CGRect(x: bounds.minX - 3, y: bounds.minY, width: bounds.width + 3, height: bounds.height); edge = .minX
        }
        menuWillOpen(menu)
        let byPress = NSEvent.pressedMouseButtons != 0
        DockMenuPopover.shared.show(menu, from: icon, rect: rect, edge: edge, byPress: byPress, keyboard: false) { [weak self] in
            self?.menuDidClose(menu)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        MenuAppearance.animateOpeningMenu()
        observedMenu = menu
        menuSnapshot = currentSnapshot()
        layoutFrames = presented
        for icon in icons.values { icon.cancelPressForMenu() }
        releasePress()
        onHold?("menu", true); onHint?(nil, .zero)
        forwardedMenuDelegate?.menuWillOpen?(menu)
    }
    func menuDidClose(_ menu: NSMenu) {
        forwardedMenuDelegate?.menuDidClose?(menu)
        forwardedMenuDelegate = nil
        observedMenu = nil; menuID = nil; menuSnapshot = nil
        menuClosedAt = ProcessInfo.processInfo.systemUptime
        onHold?("menu", false)
        onNeedsFrames?()
    }

    private func currentSnapshot(excluding source: String? = nil) -> DockMotionSnapshot {
        DockMotionSnapshot(frames: presented.filter { $0.key != source }, background: backdropRect,
                           placeholder: placeholder, separators: separators,
                           orderedIDs: items.map(\.id).filter { $0 != source })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { externalUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { externalUpdated(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    private func externalUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(sender.draggingPasteboard)
        if loggedDragSequence != sender.draggingSequenceNumber {
            loggedDragSequence = sender.draggingSequenceNumber
            let types = (sender.draggingPasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
            Self.logDrop?("外部拖入：类型 [\(types)]，来源允许操作 \(sender.draggingSourceOperationMask.rawValue)，文件 \(urls.count) 个")
        }
        guard !urls.isEmpty else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let target = DockMotionLayout.hitTest(point, frames: presented, orderedIDs: items.map(\.id), expansion: 0)
        if let target, items.first(where: { $0.id == target })?.acceptsFileDrops == false { endExternal(); return [] }
        if isInternalReference(sender.draggingPasteboard), isFileOperationTarget(target) { endExternal(); return [] }
        if !externalDrag {
            dragSizes = layoutFrames.mapValues(\.width)
            mergeSnapshot = nil
            externalDrag = true; isDragging = true; mergeIntent.reset(); onDragState?(false, true)
        }
        externalApps = urls.allSatisfy { $0.pathExtension.lowercased() == "app" }
        externalTargetID = target
        dragPoint = point
        updateIntent(at: dragPoint, time: ProcessInfo.processInfo.systemUptime)
        let allowed = sender.draggingSourceOperationMask
        if isInternalReference(sender.draggingPasteboard) { return allowed.contains(.move) ? .move : .copy }
        if isFileOperationTarget(target) {
            if target == "system:trash" { return allowed.contains(.move) ? .move : [] }
            guard copiesFiles(urls, to: target, allowed: allowed) else { return .move }
            return allowed.contains(.copy) ? .copy : []
        }
        return Self.referenceOperation(allowed)
    }
    /// 拖到文件夹入口时拷贝还是移动，规则见 FileDropOperation。
    private func copiesFiles(_ urls: [URL], to target: String?, allowed: NSDragOperation) -> Bool {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        guard let target, target.hasPrefix("file:") else { return modifiers.contains(.option) || !allowed.contains(.move) }
        return FileDropOperation.copies(urls, into: URL(fileURLWithPath: String(target.dropFirst(5))),
                                        option: modifiers.contains(.option), command: modifiers.contains(.command),
                                        moveAllowed: allowed.contains(.move))
    }
    /// 加到应用栏只记引用、不动文件：在来源允许的操作里依次选拷贝、链接、通用。来源只允许链接时
    /// （如系统 App 启动器）一律回“拷贝”会被系统判为不可放下。
    static func referenceOperation(_ allowed: NSDragOperation) -> NSDragOperation {
        [NSDragOperation.copy, .link, .generic, .move].first { allowed.contains($0) } ?? []
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let target = DockMotionLayout.hitTest(point, frames: presented, orderedIDs: items.map(\.id), expansion: 0)
        return !fileURLs(sender.draggingPasteboard).isEmpty
            && !(isInternalReference(sender.draggingPasteboard) && isFileOperationTarget(target))
            && (target.flatMap { id in items.first(where: { $0.id == id })?.acceptsFileDrops } ?? true)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragPoint = convert(sender.draggingLocation, from: nil)
        updateIntent(at: dragPoint, time: ProcessInfo.processInfo.systemUptime)
        let urls = fileURLs(sender.draggingPasteboard)
        let hit = DockMotionLayout.hitTest(dragPoint, frames: presented, orderedIDs: items.map(\.id), expansion: 0)
        let internalReference = isInternalReference(sender.draggingPasteboard)
        let gap = dragGap
        let target: String?
        if isFileOperationTarget(hit) { target = hit }
        else if urls.allSatisfy({ $0.pathExtension.lowercased() == "app" }) { target = mergeIntent.target }
        else { target = hit }
        endExternal()
        guard !urls.isEmpty, !(internalReference && isFileOperationTarget(target)) else { return false }
        let drop = DockExternalDrop(urls: urls, targetID: target, isApplicationReference: internalReference,
                                    copyFiles: copiesFiles(urls, to: target, allowed: sender.draggingSourceOperationMask),
                                    insertionIndex: target == nil ? gap : nil)
        DispatchQueue.main.async { [weak self] in self?.onExternalDrop?(drop) }
        return true
    }
    /// 分组面板里拖出的应用：不走系统拖放，面板按屏幕坐标驱动与外部拖入相同的让位与拖叠建组。
    /// 返回指针是否在应用栏上；传 nil 或指针不在栏上时结束预览。
    @discardableResult
    func updateReferenceDrag(at screenPoint: CGPoint?) -> Bool {
        guard let screenPoint, let window, window.frame.contains(screenPoint) else { endExternal(); return false }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let target = DockMotionLayout.hitTest(point, frames: presented, orderedIDs: items.map(\.id), expansion: 0)
        if isFileOperationTarget(target) || target.flatMap({ id in items.first(where: { $0.id == id })?.acceptsFileDrops }) == false {
            endExternal(); return false
        }
        if !externalDrag {
            dragSizes = layoutFrames.mapValues(\.width)
            mergeSnapshot = nil
            externalDrag = true; isDragging = true; mergeIntent.reset(); onDragState?(false, true)
        }
        externalApps = true
        externalTargetID = target
        dragPoint = point
        updateIntent(at: point, time: ProcessInfo.processInfo.systemUptime)
        onNeedsFrames?()
        return true
    }

    /// 松开：在应用栏上就移出分组、放到拖叠建组的目标或让出的空位，返回 true；不在栏上返回 false。
    func dropReference(_ url: URL, at screenPoint: CGPoint) -> Bool {
        guard updateReferenceDrag(at: screenPoint) else { return false }
        let target = mergeIntent.target, gap = dragGap
        endExternal()
        onExternalDrop?(DockExternalDrop(urls: [url], targetID: target, isApplicationReference: true,
                                         copyFiles: false, insertionIndex: target == nil ? gap : nil))
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endExternal() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endExternal() }
    private func endExternal() {
        guard externalDrag else { return }
        externalDrag = false; externalTargetID = nil; isDragging = false; mergeIntent.reset(); dragGap = nil
        dragSizes.removeAll(); mergeSnapshot = nil
        onHint?(nil, .zero); onDragState?(false, false)
        onNeedsFrames?()
    }
    private func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(\.isFileURL)
    }
    private func isInternalReference(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(NSPasteboard.PasteboardType("io.daliang.dockfolders.application-reference")) == true
    }
    private func isFileOperationTarget(_ id: String?) -> Bool {
        id?.hasPrefix("file:") == true || id == "system:trash" || id == "system:downloads"
    }

    private func updateOverlay() {
        var state = DockMotionOverlayState(separators: separators,
                                           placeholder: sourceID == nil ? nil : placeholder)
        if visualSettings.showRunningIndicators {
            for item in items where item.isRunning && item.id != sourceID {
                guard let rect = presented[item.id] else { continue }
                let dot: CGRect
                // 原生指示点约 2.4 点，圆心距屏幕边缘约 11.3 点（与图标画布底边留白重叠）。
                let inset = metrics.edgeInset - 1.9, size: CGFloat = 2.4
                switch position {
                case .bottom: dot = CGRect(x: rect.midX - size / 2, y: inset, width: size, height: size)
                case .left: dot = CGRect(x: inset, y: rect.midY - size / 2, width: size, height: size)
                case .right: dot = CGRect(x: bounds.width - inset - size, y: rect.midY - size / 2, width: size, height: size)
                }
                state.runningDots.append(dot)
            }
        }
        guard state != overlayState else { return }
        overlayState = state
        overlay.apply(state)
    }
}

@MainActor
final class DockMotionIcon: NSView {
    private(set) var item: DockDisplayItem
    weak var surface: DockMotionSurface?
    private let mergePreview = DockMergePreview()
    private var iconBitmap: CGImage?
    private var pressedBitmap: CGImage?
    private var rasterizedIcon: NSImage?
    private let badgeView = DockBadgeView()
    var badgeSuppressed = false {
        didSet {
            guard oldValue != badgeSuppressed else { return }
            let badgeView = badgeView, alpha: CGFloat = badgeSuppressed ? 0 : 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                badgeView.animator().alphaValue = alpha
            }
        }
    }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }
    private var downPoint: CGPoint?
    private var downFrame = CGRect.zero
    private var dragged = false
    private var longPressTimer: Timer?
    private var longPressTriggered = false

    init(item: DockDisplayItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        mergePreview.setAccessibilityElement(false)
        mergePreview.onActiveChange = { [weak self] in self?.needsDisplay = true }
        addSubview(mergePreview)
        badgeView.setAccessibilityElement(false)
        addSubview(badgeView)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityIdentifier(item.id)
        update(item)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ item: DockDisplayItem) {
        let badgeChanged = self.item.badge != item.badge
        self.item = item
        if rasterizedIcon !== item.icon || iconBitmap == nil {
            // 仅图像或外观改变时解析表示；悬停放大直接缩放已有纹理。按本视图的外观画（分组底板、App 的深色图标）。
            var proposed = CGRect(x: 0, y: 0, width: 128, height: 128)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                iconBitmap = item.icon.cgImage(forProposedRect: &proposed, context: nil,
                    hints: [.interpolation: NSImageInterpolation.high])
            }
            rasterizedIcon = item.icon
            pressedBitmap = nil
            mergePreview.targetImage = iconBitmap
            needsDisplay = true
        }
        setAccessibilityLabel(item.name + (item.isGroup ? "，应用文件夹" : "") + (item.isRunning ? "，正在运行" : "") + (item.badge.map { "，\($0) 条提醒" } ?? ""))
        setAccessibilityHelp("单击打开；拖到边缘排序；拖到其他图标中央松开以分组。")
        badgeView.text = item.badge
        if badgeChanged { needsLayout = true }
        mergePreview.targetIsGroup = item.isGroup
        mergePreview.memberCount = item.memberCount
    }

    var bitmap: CGImage? { iconBitmap }

    /// 系统切换深浅色：位图是按旧外观画的，重画一次。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        iconBitmap = nil
        update(item)
    }
    /// 拖动图标落入的位置（图标坐标）。
    var mergeLandingRect: CGRect { mergePreview.landingRect }
    func setMerge(_ state: DockMergePreview.State) { mergePreview.setState(state) }
    func landSource(_ image: CGImage?) { mergePreview.landSource(image) }
    override func accessibilityPerformPress() -> Bool { surface?.open(item.id); return true }
    /// 与原生 Dock 的格子一致，辅助功能可直接弹出右键菜单（VoiceOver 的“显示菜单”）。
    override func accessibilityPerformShowMenu() -> Bool { surface?.showMenu(for: item.id); return true }
    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        if event.modifierFlags.contains(.control) { surface.showMenu(for: item.id); return }
        cancelLongPress()
        downPoint = surface.convert(event.locationInWindow, from: nil)
        downFrame = frame
        if let downPoint { surface.press(item.id, point: downPoint) }
        dragged = false; pressed = true; longPressTriggered = false
        let timer = Timer(timeInterval: 0.55, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.dragged, !self.longPressTriggered,
                      let surface = self.surface, !surface.isDragging else { return }
                self.longPressTimer = nil
                self.longPressTriggered = true
                self.pressed = false
                surface.releasePress()
                // 与右键、键盘菜单使用同一份 NSMenu，菜单关闭后不再触发单击。
                surface.showMenu(for: self.item.id)
            }
        }
        longPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func mouseDragged(with event: NSEvent) {
        // 长按弹出菜单后不松手，拖到菜单项上松开即选中。
        if DockMenuPopover.shared.trackPress(at: NSEvent.mouseLocation) { return }
        guard let downPoint, let surface, !longPressTriggered else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        if !dragged, hypot(point.x - downPoint.x, point.y - downPoint.y) > 5 {
            cancelLongPress()
            dragged = true; pressed = false
            surface.beginDrag(self, event: event, originalPoint: downPoint, originalFrame: downFrame)
        } else if dragged { surface.moveDrag(event) }
    }
    override func mouseUp(with event: NSEvent) {
        cancelLongPress()
        if DockMenuPopover.shared.releasePress(at: NSEvent.mouseLocation) { return }
        guard downPoint != nil, let surface else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        let wasDragged = dragged
        let wasLongPress = longPressTriggered
        surface.releasePress()
        downPoint = nil; dragged = false; pressed = false; longPressTriggered = false
        if wasDragged { surface.finishDrag(at: point, cancelled: false) }
        else if !wasLongPress, frame.contains(point) { surface.open(item.id) }
    }
    func cancelPressForMenu() {
        cancelLongPress()
        downPoint = nil; dragged = false; pressed = false; longPressTriggered = true
    }
    private func cancelLongPress() {
        longPressTimer?.invalidate(); longPressTimer = nil
    }
    override func menu(for event: NSEvent) -> NSMenu? { surface?.makeMenu(id: item.id) }
    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        cancelLongPress()
        surface.showMenu(for: item.id)
    }
    override func rightMouseDragged(with event: NSEvent) { DockMenuPopover.shared.trackPress(at: NSEvent.mouseLocation) }
    override func rightMouseUp(with event: NSEvent) { DockMenuPopover.shared.releasePress(at: NSEvent.mouseLocation) }
    // 图像直接作为图层内容并按框缩放：悬停放大时由 Core Animation 缩放，不依赖重绘。
    // 之前在 draw 里绘制、依赖 AppKit 缩放旧内容，实际画面不随放大变大（框变大、图标不变）。
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        // 合并预览接管图标画面（目标图标改由预览里的图层显示，才能缩进格子、垫上底板）。
        // 按下照系统 Dock：换成颜色乘 0.4 的图，透明度不变，玻璃不会透上来。
        if pressed, pressedBitmap == nil, let iconBitmap { pressedBitmap = DockPressDarkening.darkened(iconBitmap) }
        layer.contents = mergePreview.isActive ? nil : pressed ? pressedBitmap ?? iconBitmap : iconBitmap
    }
    override func layout() {
        super.layout()
        if mergePreview.frame != bounds { mergePreview.frame = bounds }
        let badgeFrame = badgeView.frame(inIcon: bounds)
        if badgeView.frame != badgeFrame { badgeView.frame = badgeFrame }
    }
}

/// iPhone 式拖叠建组预览，全部是图层：
/// - 可松开（拖到目标中央）：底板弹性放大，目标图标缩进左上格（与分组图标的第一格重合）；拖到已有分组上时分组图标放大。
/// - 落入：底板回到正常大小，拖动图标落进下一格后显示在格内，随后真实分组图标接替。
/// - 拖离：弹回原样，动画结束后隐藏，图标画面交还给图标视图。
@MainActor
final class DockMergePreview: NSView {
    enum State: Equatable { case none, armed, landing }

    private let folder = CALayer()
    private let plate = CALayer()
    private let target = CALayer()
    private let source = CALayer()
    private var state = State.none
    private var hideWork: DispatchWorkItem?
    private(set) var isActive = false { didSet { if oldValue != isActive { onActiveChange?() } } }
    var onActiveChange: (() -> Void)?
    var targetImage: CGImage? { didSet { target.contents = targetImage } }
    var targetIsGroup = false
    var memberCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let still: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(),
                                             "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        for sublayer in [folder, plate, target, source] { sublayer.actions = still }
        target.contentsGravity = .resize; target.minificationFilter = .trilinear
        source.contentsGravity = .resize; source.minificationFilter = .trilinear
        folder.addSublayer(plate); folder.addSublayer(target); folder.addSublayer(source)
        layer?.addSublayer(folder)
        isHidden = true
        plate.opacity = 0; source.opacity = 0
        recolor()
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); recolor() }

    /// 拖动图标落入的格子：新分组为右上格；加入已有分组为下一个空格。
    var landingRect: CGRect {
        guard targetIsGroup else { return GroupIconGeometry.slot(1, memberCount: 2, in: bounds) }
        return GroupIconGeometry.slot(min(memberCount, 8), memberCount: memberCount + 1, in: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        folder.bounds = bounds; folder.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let plateRect = GroupIconGeometry.plate(in: bounds)
        plate.bounds = CGRect(origin: .zero, size: plateRect.size)
        plate.position = CGPoint(x: plateRect.midX, y: plateRect.midY)
        plate.cornerRadius = GroupIconGeometry.cornerRadius(of: plateRect)
        plate.borderWidth = max(0.5, bounds.width / 128)
        target.bounds = bounds; target.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let landing = landingRect
        source.bounds = CGRect(origin: .zero, size: landing.size)
        source.position = CGPoint(x: landing.midX, y: landing.midY)
        apply(animated: false)
        CATransaction.commit()
    }

    func setState(_ next: State) {
        guard next != state else { return }
        state = next
        hideWork?.cancel(); hideWork = nil
        if next != .none { isActive = true; isHidden = false }
        if next != .landing, source.opacity != 0 { source.opacity = 0 }
        apply(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard next == .none else { return }
        // 弹回动画结束后再隐藏，画面交还给图标视图。
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .none else { return }
            self.isHidden = true; self.isActive = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 拖动图标到位：在落入格里显示它，直到真实分组图标接替。
    func landSource(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        source.contents = image
        source.opacity = image == nil ? 0 : 1
        CATransaction.commit()
    }

    private func apply(animated: Bool) {
        guard bounds.width > 0 else { return }
        var folderScale: CGFloat = 1, plateOpacity: Float = 0, plateScale: CGFloat = 1
        var targetTransform = CATransform3DIdentity
        let slot = GroupIconGeometry.slot(0, memberCount: 2, in: bounds)
        let slotScale = slot.width / bounds.width
        let toFirstSlot = CATransform3DScale(CATransform3DMakeTranslation(slot.midX - bounds.midX, slot.midY - bounds.midY, 0), slotScale, slotScale, 1)
        switch state {
        case .none:
            plateScale = 0.92
        case .armed:
            folderScale = targetIsGroup ? 1.15 : 1.1
            if !targetIsGroup { plateOpacity = 1; targetTransform = toFirstSlot }
        case .landing:
            if !targetIsGroup { plateOpacity = 1; targetTransform = toFirstSlot }
        }
        set(folder, transform: CATransform3DMakeScale(folderScale, folderScale, 1), animated: animated)
        set(plate, transform: CATransform3DMakeScale(plateScale, plateScale, 1), animated: animated)
        set(target, transform: targetTransform, animated: animated)
        guard plate.opacity != plateOpacity else { return }
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = plate.presentation()?.opacity ?? plate.opacity
            fade.toValue = plateOpacity
            fade.duration = 0.2
            plate.add(fade, forKey: "opacity")
        }
        plate.opacity = plateOpacity
    }

    private func set(_ layer: CALayer, transform: CATransform3D, animated: Bool) {
        guard !CATransform3DEqualToTransform(layer.transform, transform) else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        layer.transform = transform
        guard animated else { layer.removeAnimation(forKey: "transform"); return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: transform)
        spring.mass = 1; spring.stiffness = 260; spring.damping = 20
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "transform")
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            plate.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
            plate.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        }
    }
}

/// 系统菜单出场没有动画。实测菜单即将打开（menuWillOpen）时，它的窗口 NSPopupMenuWindow 已建好但未上屏，
/// 约 25ms 后以完全不透明的状态出现。这里先把窗口设为透明，上屏后 0.16 秒淡入并上浮 6 点；找不到窗口时不做任何事。
@MainActor
final class MenuAppearance: NSObject, NSMenuDelegate {
    static let shared = MenuAppearance()
    func menuWillOpen(_ menu: NSMenu) { Self.animateOpeningMenu() }

    static func animateOpeningMenu() {
        guard let window = NSApp.windows.last(where: { !$0.isVisible && String(describing: type(of: $0)) == "NSPopupMenuWindow" }) else { return }
        window.alphaValue = 0
        MenuFadeIn(window: window).start()
    }
}

@MainActor
private final class MenuFadeIn {
    private let window: NSWindow
    private let created = ProcessInfo.processInfo.systemUptime
    private var shownAt: TimeInterval?
    private var origin = CGPoint.zero
    private var timer: Timer?

    init(window: NSWindow) { self.window = window }

    /// 计时器持有自己直到动画结束；放在 common 模式，菜单跟踪期间照常运行。
    func start() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [self] _ in MainActor.assumeIsolated { step() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        guard window.isVisible else {
            // 菜单被取消或已收起：恢复不透明，免得复用的窗口下次仍是透明的。
            if shownAt != nil || now - created > 1 { window.alphaValue = 1; finish() }
            return
        }
        if shownAt == nil { shownAt = now; origin = window.frame.origin }
        let progress = min(1, (now - (shownAt ?? now)) / 0.16)
        let eased = 1 - pow(1 - progress, 3)
        window.alphaValue = eased
        window.setFrameOrigin(CGPoint(x: origin.x, y: origin.y - 6 * (1 - eased)))
        if progress >= 1 { finish() }
    }

    private func finish() { timer?.invalidate(); timer = nil }
}

/// 未读角标：独立小视图，按图标尺寸等比定位与缩放。放大、收回时只改框不重画，始终贴在图标右上角。
/// 原先画在随图标拉伸的叠层里，叠层只在状态变化时重画，放大过程中角标会先被拉伸、重画时再跳位。
@MainActor
private final class DockBadgeView: NSView {
    /// 37 点图标上的参考尺寸，按原生 Dock 同尺寸截图实测：高 14 点；1～2 位数是直径 14 的正圆，
    /// 3 位数宽 16、4 位数宽 21（完整显示数字）；7 点常规字重；右缘、顶边与图标齐平。
    private static let referenceIcon: CGFloat = 37
    private static let height: CGFloat = 14
    /// 文字左右合计留白：按原生 3 位数宽 16、4 位数宽 21 与 7 点字宽反推。
    private static let horizontalPadding: CGFloat = 3.6
    /// 按最大放大尺寸的 2 倍像素渲染，缩小时三线性采样。
    private static let renderScale: CGFloat = 2 * 64 / 37
    private var image: CGImage?
    private var referenceSize = CGSize.zero
    var text: String? { didSet { if oldValue != text { rebuild() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.contents = image
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rebuild() }

    func frame(inIcon icon: CGRect) -> CGRect {
        let scale = icon.width / Self.referenceIcon
        let size = CGSize(width: referenceSize.width * scale, height: referenceSize.height * scale)
        return CGRect(x: icon.maxX - size.width, y: icon.maxY - size.height, width: size.width, height: size.height)
    }

    private func rebuild() {
        guard let text, !text.isEmpty else { image = nil; isHidden = true; return }
        let font = NSFont.systemFont(ofSize: 7, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attributes)
        // 宽度就近取到半点，2 倍屏上边缘落在整像素。
        let size = CGSize(width: max(Self.height, ((textSize.width + Self.horizontalPadding) * 2).rounded() / 2), height: Self.height)
        referenceSize = size
        let pixels = (width: Int(ceil(size.width * Self.renderScale)), height: Int(ceil(size.height * Self.renderScale)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 按取整后的像素铺满：位图会被拉伸到角标框，按固定倍率画会让图形比框小约半像素。
        context.scaleBy(x: CGFloat(pixels.width) / size.width, y: CGFloat(pixels.height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: size.height / 2, yRadius: size.height / 2).fill()
            // 按数字高度（大写字母高）上下居中：绘制原点在行底，基线在其上方 |descender| 处。
            (text as NSString).draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - font.capHeight) / 2 + font.descender), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        image = context.makeImage()
        isHidden = false
        needsDisplay = true
    }
}

/// 原生 Dock 名称标签样式：玻璃胶囊 + 指向图标的小尖角。
@MainActor
final class HintBubbleView: NSView {
    static let bodyHeight: CGFloat = 23
    static let tailHeight: CGFloat = 4

    /// 名称提示窗口：浮在应用栏和分组面板之上，不接收鼠标。
    static func makePanel(title: String) -> (NSPanel, NSTextField) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        // 原生 Dock 标签：液态玻璃胶囊（高约 23 点）加底部约 4 点的小尖角。
        let container = HintBubbleView()
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 13); label.alignment = .center
        container.label = label
        panel.contentView = container
        return (panel, label)
    }
    var label: NSTextField? { didSet { oldValue?.removeFromSuperview(); if let label { glassContent.addSubview(label) } } }
    var tailX: CGFloat? { didSet { if oldValue != tailX { needsLayout = true } } }
    private let glass: NSView
    private let glassContent = NSView()
    private let shape = CAShapeLayer()

    init() {
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(); effect.style = .regular; effect.contentView = glassContent; glass = effect
        } else {
            let effect = NSVisualEffectView(); effect.material = .toolTip; effect.blendingMode = .behindWindow; effect.state = .active
            effect.addSubview(glassContent); glass = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glass)
        layer?.mask = shape
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glassContent.frame = bounds
        let body = CGRect(x: 0, y: Self.tailHeight, width: bounds.width, height: Self.bodyHeight)
        label?.frame = CGRect(x: 8, y: body.minY + 3, width: bounds.width - 16, height: 17)
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: body.height / 2, cornerHeight: body.height / 2)
        let tip = min(max(tailX ?? bounds.midX, body.height / 2 + 4), bounds.width - body.height / 2 - 4)
        path.move(to: CGPoint(x: tip - 5, y: body.minY + 0.5))
        path.addLine(to: CGPoint(x: tip, y: 0))
        path.addLine(to: CGPoint(x: tip + 5, y: body.minY + 0.5))
        path.closeSubpath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds; shape.path = path
        if #available(macOS 26.0, *) { (glass as? NSGlassEffectView)?.cornerRadius = 0 }
        CATransaction.commit()
    }
}

private struct DockMotionOverlayState: Equatable {
    var separators: [CGRect] = []
    var placeholder: CGRect?
    var runningDots: [CGRect] = []
}

/// 分隔线、拖动占位和运行指示点：每个元素一个小图层，放大时只移动图层。
/// 原先整层用 CPU 重画，图标每帧移动都要重绘整条画布并等待上一帧缓冲释放。
@MainActor
private final class DockMotionOverlay: NSView {
    private var separatorLayers: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private let placeholderLayer = CALayer()
    private var state = DockMotionOverlayState()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        placeholderLayer.cornerRadius = 8
        placeholderLayer.isHidden = true
        layer?.addSublayer(placeholderLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ state: DockMotionOverlayState) {
        self.state = state
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let addedSeparators = sync(&separatorLayers, count: state.separators.count)
        let addedDots = sync(&dotLayers, count: state.runningDots.count)
        if addedSeparators || addedDots { recolor() }
        for (layer, rect) in zip(separatorLayers, state.separators) { layer.frame = rect }
        for (layer, rect) in zip(dotLayers, state.runningDots) { layer.frame = rect; layer.cornerRadius = rect.width / 2 }
        placeholderLayer.isHidden = state.placeholder == nil
        if let placeholder = state.placeholder { placeholderLayer.frame = placeholder.insetBy(dx: 2, dy: 2) }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        recolor()
        CATransaction.commit()
    }

    /// 返回是否新建了图层（新图层需要上色）。
    private func sync(_ layers: inout [CALayer], count: Int) -> Bool {
        while layers.count > count { layers.removeLast().removeFromSuperlayer() }
        guard layers.count < count else { return false }
        while layers.count < count {
            let sublayer = CALayer()
            sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(sublayer)
            layers.append(sublayer)
        }
        return true
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for sublayer in separatorLayers { sublayer.backgroundColor = NSColor.separatorColor.cgColor }
            for sublayer in dotLayers { sublayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor }
            placeholderLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

@MainActor
private final class DockMotionGhost: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var removing = false { didSet { if oldValue != removing { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: removing ? 0.45 : 0.9)
    }
}
