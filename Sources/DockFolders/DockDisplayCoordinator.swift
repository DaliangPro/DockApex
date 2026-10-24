import AppKit
import CoreGraphics

struct DockDisplayDescriptor: Equatable, Sendable {
    var uuid: String
    var name: String
    var isPrimary: Bool
    var displayID: UInt32
    var frame: CGRect

    @MainActor
    init(screen: NSScreen, primary: NSScreen?) {
        let currentID = Self.identifier(for: screen)
        uuid = Self.uuid(for: screen)
        name = screen.localizedName
        displayID = currentID
        isPrimary = primary.map { Self.identifier(for: $0) == currentID } ?? false
        frame = screen.frame
    }

    @MainActor
    static func uuid(for screen: NSScreen) -> String {
        let identifier = identifier(for: screen)
        if let value = CGDisplayCreateUUIDFromDisplayID(identifier)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, value) as String
        }
        // 极少数虚拟显示器没有系统 UUID。保留可识别的屏幕名称作为降级身份，不能伪装成稳定硬件 UUID。
        return "virtual:" + screen.localizedName + ":" + String(identifier)
    }

    @MainActor
    private static func identifier(for screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// 保留整个屏幕边缘的基础厚度，悬停放大不应使其他应用窗口跟着跳动。
struct DockReservedArea: Equatable, Sendable {
    var displayUUID: String
    var screenFrame: CGRect
    var reservedFrame: CGRect
    var position: DockPosition
}

/// 多条应用栏共用数据和操作回调，但各自管理鼠标、放大、自动隐藏与拖放状态。
@MainActor
final class DockDisplayCoordinator {
    var onGeometryChanged: (() -> Void)?
    var onPresentationChanged: (() -> Void)?
    var onMenuState: ((Bool) -> Void)?
    var isAnyBarPresented: Bool { bars.values.contains(where: \.isPresented) }
    var isAnyBarHovered: Bool { bars.values.contains(where: \.isHovering) }
    var isAnyBarNear: Bool { bars.values.contains(where: \.isNear) }
    private let onOpen: (String, CGPoint) -> Void
    private let onMerge: (String, String) -> Void
    private let onReorder: (String, Int) -> Void
    private let onExternalDrop: (DockExternalDrop) -> Void
    private let onContext: (String) -> NSMenu
    private let onRemove: (String) -> Void
    private let onFocus: (Bool) -> Void
    private var bars: [String: DockBarController] = [:]
    private var activeKey: String?
    private var anchorOwners: [String: String] = [:]
    private var holdOwners: [String: String] = [:]
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var items: [DockDisplayItem] = []
    private var position = DockPosition.bottom
    private var autoHide = false
    private var appearance = DockBarAppearance.nativeDefaults
    private var mode = DockDisplayMode.followPointer
    private var requestedUUID: String?
    private var fullscreenDisplays = Set<UInt32>()
    private var enabled = false
    private var isReconcilingDisplays = false
    private var lastReservedAreas: [DockReservedArea] = []
    private var lastActiveDisplayUUID: String?
    private static let followingKey = "follow-pointer"

    init(onOpen: @escaping (String, CGPoint) -> Void,
         onMerge: @escaping (String, String) -> Void,
         onReorder: @escaping (String, Int) -> Void,
         onExternalDrop: @escaping (DockExternalDrop) -> Void,
         onContext: @escaping (String) -> NSMenu,
         onRemove: @escaping (String) -> Void = { _ in },
         onFocus: @escaping (Bool) -> Void = { _ in }) {
        self.onOpen = onOpen; self.onMerge = onMerge; self.onReorder = onReorder
        self.onExternalDrop = onExternalDrop; self.onContext = onContext
        self.onRemove = onRemove; self.onFocus = onFocus
    }

    static var availableDisplays: [DockDisplayDescriptor] {
        let screens = NSScreen.screens
        return screens.map { DockDisplayDescriptor(screen: $0, primary: screens.first) }
    }

    var activeDisplayUUID: String? { activeBar?.displayUUID }
    var visibleDockAreas: [DockReservedArea] {
        bars.values.compactMap(\.reservedArea).sorted { $0.displayUUID < $1.displayUUID }
    }
    var frameTimingSummaries: [String: Any] { bars.mapValues { $0.frameTimingSummary } }
    var itemFramesForDiagnostics: [[String: Any]] { orderedBars.flatMap { $0.itemFramesForDiagnostics } }
    var hoveredItemID: String? { bars.values.first(where: { $0.isHovering })?.hoveredItemID }

    /// 分组面板拖出的应用：交给指针所在的那条应用栏，其余结束预览。
    @discardableResult
    func updateReferenceDrag(at point: CGPoint?) -> Bool {
        var over = false
        for bar in bars.values where bar.updateReferenceDrag(at: over ? nil : point) { over = true }
        return over
    }

    func dropReference(_ url: URL, at point: CGPoint) -> Bool {
        var accepted = false
        for bar in bars.values {
            if !accepted, bar.dropReference(url, at: point) { accepted = true } else { bar.updateReferenceDrag(at: nil) }
        }
        return accepted
    }

    func pointerNudged(at point: CGPoint) {
        for bar in bars.values { bar.pointerNudged(at: point) }
    }

    func runSweepBenchmark(duration: TimeInterval) {
        orderedBars.first?.runSweepBenchmark(duration: duration)
    }

    func show(items: [DockDisplayItem], position: DockPosition, autoHide: Bool,
              appearance: DockBarAppearance = .nativeDefaults,
              displayMode: DockDisplayMode = .followPointer, displayUUID: String? = nil) {
        self.items = items; self.position = position; self.autoHide = autoHide
        self.appearance = appearance; mode = displayMode; requestedUUID = displayUUID
        enabled = true
        installObservers()
        reconcileDisplays()
    }

    /// 默认使用最近发生点击、右键、拖放或键盘操作的应用栏，防止展开面板跳到另一屏。
    func anchorRect(for id: String, nearAppKitPoint point: CGPoint? = nil) -> CGRect? {
        if let point, let match = nearestBar(to: point), let rect = match.anchorRect(for: id) { return rect }
        if let owner = anchorOwners[id], let rect = bars[owner]?.anchorRect(for: id) { return rect }
        return activeBar?.anchorRect(for: id) ?? orderedBars.compactMap { $0.anchorRect(for: id) }.first
    }

    /// 指针所在的应用栏上这个条目的预览弹出位置。
    func previewAnchor(for id: String, nearAppKitPoint point: CGPoint) -> WindowPreviewController.Anchor? {
        (nearestBar(to: point) ?? activeBar)?.previewAnchor(for: id)
    }

    func anchorRects(for id: String) -> [CGRect] { orderedBars.compactMap { $0.anchorRect(for: id) } }
    /// 当前应用栏上未放大时的位置。
    func restingRect(for id: String) -> CGRect? { activeBar?.restingRect(for: id) }
    /// 链接、管理窗口等不经应用栏单击的展开，也像单击一样锁定静止布局，面板对准静止的图标。
    func retainGroupAnchor(_ id: String) { (anchorOwners[id].flatMap { bars[$0] } ?? activeBar)?.retainGroupAnchor(id) }

    func setInteractionHold(_ reason: String, active: Bool) {
        if active {
            guard let key = selectedKey, let bar = bars[key] else { return }
            if let previous = holdOwners[reason], previous != key { bars[previous]?.setInteractionHold(reason, active: false) }
            holdOwners[reason] = key
            bar.setInteractionHold(reason, active: true)
        } else if let key = holdOwners.removeValue(forKey: reason) {
            bars[key]?.setInteractionHold(reason, active: false)
        }
    }


    func setFullscreenDisplays(_ displays: Set<UInt32>) {
        fullscreenDisplays = displays
        isReconcilingDisplays = true
        for bar in bars.values { bar.setFullscreenDisplays(displays) }
        isReconcilingDisplays = false
        geometryChanged()
    }

    func hide() {
        enabled = false
        isReconcilingDisplays = true
        for bar in bars.values { bar.hide() }
        bars.removeAll(); holdOwners.removeAll(); anchorOwners.removeAll(); activeKey = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        isReconcilingDisplays = false
        geometryChanged()
    }

    private var orderedBars: [DockBarController] { bars.keys.sorted().compactMap { bars[$0] } }
    func hideNameHints() { for bar in bars.values { bar.hideNameHint() } }
    private var selectedKey: String? { activeKey.flatMap { bars[$0] != nil ? $0 : nil } ?? bars.keys.sorted().first }
    private var activeBar: DockBarController? { selectedKey.flatMap { bars[$0] } }

    private func nearestBar(to point: CGPoint) -> DockBarController? {
        if let contained = orderedBars.first(where: { $0.displayFrame?.contains(point) == true }) { return contained }
        return orderedBars.min { lhs, rhs in
            guard let a = lhs.displayFrame, let b = rhs.displayFrame else { return lhs.displayFrame != nil }
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        }
    }

    private func reconcileDisplays() {
        guard enabled else { return }
        isReconcilingDisplays = true
        defer { isReconcilingDisplays = false; geometryChanged() }
        let displays = Self.availableDisplays
        let resolved = DockDisplayRouting.resolvedUUIDs(mode: mode, requestedUUID: requestedUUID,
                                                       availableUUIDs: displays.map(\.uuid),
                                                       primaryUUID: displays.first(where: \.isPrimary)?.uuid)
        let keys = mode == .followPointer && !resolved.isEmpty ? [Self.followingKey] : resolved
        let wanted = Set(keys)
        for key in Array(bars.keys) where !wanted.contains(key) {
            bars.removeValue(forKey: key)?.hide()
            holdOwners = holdOwners.filter { $0.value != key }
            anchorOwners = anchorOwners.filter { $0.value != key }
        }
        for key in keys {
            let bar: DockBarController
            if let existing = bars[key] { bar = existing }
            else { bar = makeBar(key: key); bars[key] = bar }
            bar.setDisplay(uuid: mode == .followPointer ? nil : key)
            bar.setFullscreenDisplays(fullscreenDisplays)
            bar.show(items: items, position: position, autoHide: autoHide, appearance: appearance)
        }
        if activeKey.flatMap({ bars[$0] }) == nil { activeKey = keys.first }
        let itemIDs = Set(items.map(\.id))
        anchorOwners = anchorOwners.filter { itemIDs.contains($0.key) }
    }

    private func makeBar(key: String) -> DockBarController {
        let bar = DockBarController(
            onOpen: { [weak self] id, point in
                self?.recordInteraction(key: key, anchorID: id)
                self?.onOpen(id, point)
            },
            onMerge: { [weak self] source, target in self?.recordInteraction(key: key); self?.onMerge(source, target) },
            onReorder: { [weak self] id, index in self?.recordInteraction(key: key); self?.onReorder(id, index) },
            onExternalDrop: { [weak self] drop in self?.recordInteraction(key: key); self?.onExternalDrop(drop) },
            onContext: { [weak self] id in self?.recordInteraction(key: key); return self?.onContext(id) ?? NSMenu() },
            onRemove: { [weak self] id in self?.recordInteraction(key: key); self?.onRemove(id) },
            onFocus: { [weak self] focused in if focused { self?.recordInteraction(key: key) }; self?.onFocus(focused) })
        bar.onGeometryChanged = { [weak self] in self?.geometryChanged() }
        bar.onPresentationChanged = { [weak self] _ in self?.onPresentationChanged?() }
        bar.onMenuState = { [weak self] open in self?.onMenuState?(open) }
        return bar
    }

    private func recordInteraction(key: String, anchorID: String? = nil) {
        guard bars[key] != nil else { return }
        if let anchorID { anchorOwners[anchorID] = key }
        guard activeKey != key else { return }
        activeKey = key
        geometryChanged()
    }

    private func geometryChanged() {
        guard !isReconcilingDisplays else { return }
        let areas = visibleDockAreas
        let activeDisplay = activeDisplayUUID
        guard lastReservedAreas != areas || lastActiveDisplayUUID != activeDisplay else { return }
        // 先提交去重状态，再通知外部；回调同步刷新应用栏时不会重复进入同一变更。
        lastReservedAreas = areas
        lastActiveDisplayUUID = activeDisplay
        onGeometryChanged?()
    }

    private func installObservers() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcileDisplays() }
            }
        }
        if workspaceObservers.isEmpty {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcileDisplays() }
            })
        }
    }
}
