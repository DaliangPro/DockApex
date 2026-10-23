import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

/// 影子 Dock：系统 Dock 保持显示，负责系统占位（含已运行进程与输入法 HUD）和最小化终点；
/// 本控制器让它停在应用栏所在屏，并用一块实时补底遮住它。
/// 补底画面来自屏幕捕捉，仅覆盖系统 Dock 那一条区域，只在内存中使用，不保存、不上传。
@MainActor
final class ShadowDockController: NSObject {
    private let base = ShadowPatch(title: "Dock 文件夹 · 补底", level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1))
    private let label = ShadowPatch(title: "Dock 文件夹 · 标签遮盖", level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1), masked: true)
    /// 指针在系统 Dock 图标区移动时，移动事件被拦截，应用读到的指针位置不再更新；
    /// 这里把拦截到的真实位置（AppKit 屏幕坐标）交给应用栏。
    var onPointerInDock: ((CGPoint) -> Void)?
    private lazy var edgeGuard = DockEdgeGuard(onDockMove: { [weak self] in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliverDockPointer() } }
    })
    private var lastShadowScan: TimeInterval = 0
    private var fastShadowsUntil: TimeInterval = 0
    private var locksTarget = false
    private var nativeTiles: [NativeDockTile] = []
    private var labelRegion: CGRect?
    private var labelTimer: Timer?
    private var currentLabel: CGRect?
    private var fadingLabels: [(rect: CGRect, until: TimeInterval)] = []
    private var hovering = false
    private var near = false
    private var menuOpen = false
    private var hoverEnd: DispatchWorkItem?
    private var timer: Timer?
    private var shadowTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var casters: [WindowShadowCaster] = []
    private var scanningShadows = false
    /// 补底窗口的位置：它的画面里已经带着画回的阴影，其它遮盖叠阴影时要避开。
    var patchFrame: CGRect? { base.visibleFrame }
    private var reading = false
    private var targetDisplayUUID: String?
    private var visible = true
    private var fullscreenDisplays = Set<UInt32>()
    private var lastRelocation: TimeInterval = 0
    private var relocationAttempts = 0
    private var mismatchSince: TimeInterval?
    private(set) var nativeFrame: CGRect?
    private(set) var lastError: String?
    private var running = false

    var summary: [String: Any] {
        ["running": running, "nativeFrame": nativeFrame.map { NSStringFromRect($0) } ?? "", "target": targetDisplayUUID ?? "",
         "patchVisible": base.isVisible, "streaming": base.isStreaming, "labelCover": label.isVisible,
         "labelStreaming": label.isStreaming, "menuOpen": menuOpen,
         "patchIncludesApps": base.includesApps, "patchShadowCasters": base.shadowCasterCount,
         "patchActiveShadow": base.hasActiveShadow, "labelVisibleRects": (currentLabel == nil ? 0 : 1) + fadingLabels.count,
         "nativeTiles": nativeTiles.count, "edgeGuard": edgeGuard.summary, "locksTarget": locksTarget,
         "relocationAttempts": relocationAttempts, "error": lastError ?? base.lastError ?? label.lastError ?? ""]
    }

    func start() {
        guard !running else { return }
        running = true
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 拖动窗口时阴影要跟手；只读窗口列表，变化时才重画。
        let shadowTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.shadowTick() } }
        shadowTimer.tolerance = 0.005
        RunLoop.main.add(shadowTimer, forMode: .common)
        self.shadowTimer = shadowTimer
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShadows() }
        }
        poll()
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        shadowTimer?.invalidate(); shadowTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        base.hide(); label.hide()
        labelTimer?.invalidate(); labelTimer = nil
        edgeGuard.setZones(edges: [], dock: [])
        nativeFrame = nil
        nativeTiles = []
        casters = []
    }

    /// 应用栏当前所在屏；nil 表示不主动迁移（例如多屏同时显示时跟随系统 Dock 所在屏）。
    /// `locked` 为真表示应用栏固定在这块屏（主屏或指定屏）：系统 Dock 不能被推去别的屏。
    func setTarget(displayUUID: String?, locked: Bool) {
        guard targetDisplayUUID != displayUUID || locksTarget != locked else { return }
        targetDisplayUUID = displayUUID
        locksTarget = locked
        relocationAttempts = 0
        updateEdgeGuard()
        poll()
    }

    private func deliverDockPointer() {
        guard let location = edgeGuard.takeDockLocation() else { return }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        onPointerInDock?(CGPoint(x: location.x, y: primaryHeight - location.y))
    }

    /// 固定屏时在其它屏的 Dock 所在边拦截推边（跟随指针或同时显示时不拦截）；
    /// 系统 Dock 图标区始终拦截移动，让它不再冒名称标签。全屏时系统 Dock 不在画面里，不拦截图标区。
    private func updateEdgeGuard() {
        guard running else { edgeGuard.setZones(edges: [], dock: []); return }
        let orientation = ShadowDockGeometry.orientation()
        var edges: [CGRect] = []
        if locksTarget, NSScreen.screens.count > 1, let targetDisplayUUID,
           let target = NSScreen.screens.first(where: { DockDisplayDescriptor.uuid(for: $0) == targetDisplayUUID }) {
            edges = DockEdgeGuard.zones(excluding: target, orientation: orientation)
        }
        var dock: [CGRect] = []
        if orientation == .bottom, let frame = nativeFrame, let screen = screen(containing: frame),
           !fullscreenDisplays.contains((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) {
            dock = [DockEdgeGuard.dockZone(nativeFrame: frame, on: screen)]
        }
        edgeGuard.setZones(edges: edges, dock: dock)
    }

    /// 应用栏在全屏或自动隐藏时退出画面，系统 Dock 也随之隐藏，补底无需显示。
    func setBarVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        updatePatch()
    }

    func refreshNow() { poll() }

    /// 指针在应用栏上时显示标签遮盖。
    /// 指针接近应用栏时预热标签遮盖的捕捉。
    func setNear(_ value: Bool) {
        guard near != value else { return }
        near = value
        updatePatch()
    }

    func setMenuOpen(_ value: Bool) {
        guard menuOpen != value else { return }
        menuOpen = value
        updatePatch()
    }

    func setHovering(_ value: Bool) {
        hoverEnd?.cancel(); hoverEnd = nil
        if value {
            guard !hovering else { return }
            hovering = true
            updatePatch()
            return
        }
        guard hovering else { return }
        // 系统 Dock 的标签在指针离开后还会淡出一阵，稍后再撤遮盖。
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hovering = false; self.hoverEnd = nil
            self.updatePatch()
        }
        hoverEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// 全屏空间里没有壁纸，补底改为捕捉全屏 App 的实际画面（排除系统 Dock 与本应用窗口）。
    func setFullscreenDisplays(_ displays: Set<UInt32>) {
        guard fullscreenDisplays != displays else { return }
        fullscreenDisplays = displays
        updateEdgeGuard()
        updatePatch()
    }

    private func poll() {
        guard running, !reading else { return }
        reading = true
        let own = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task.detached(priority: .userInitiated) {
            let native = ShadowDockGeometry.readNativeDock()
            let casters = ShadowDockGeometry.shadowCasters(excluding: own, frontmost: frontmost)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.running else { return }
                self.nativeFrame = native?.frame
                self.nativeTiles = native?.tiles ?? []
                self.updateEdgeGuard()
                self.casters = casters
                self.relocateIfNeeded()
                self.updatePatch()
            }
        }
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
            .flatMap { $0.frame.intersects(rect) ? $0 : nil }
    }

    private func relocateIfNeeded() {
        guard let targetDisplayUUID, let frame = nativeFrame,
              let target = NSScreen.screens.first(where: { DockDisplayDescriptor.uuid(for: $0) == targetDisplayUUID }) else { return }
        // 只有系统 Dock 完整显示在某块屏上时才判断是否需要迁移；全屏或自动隐藏时它在屏外，位置读数不代表所在屏。
        func displayID(_ screen: NSScreen) -> UInt32 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
        guard !fullscreenDisplays.contains(displayID(target)),
              let shown = NSScreen.screens.first(where: { $0.frame.intersection(frame).height >= frame.height * 0.9 }),
              !fullscreenDisplays.contains(displayID(shown)) else { mismatchSince = nil; return }
        if let current = screen(containing: frame), DockDisplayDescriptor.uuid(for: current) == targetDisplayUUID {
            relocationAttempts = 0; mismatchSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // 跟随指针时，用户正在别的屏边缘推出系统 Dock，应用栏会随指针迁移，此时不要把它推回去；
        // 固定屏时应用栏不会过去，系统 Dock 必须回来。
        if !locksTarget, let current = screen(containing: frame),
           DockMotionLayout.isAtEdge(NSEvent.mouseLocation, screen: current.frame, position: ShadowDockGeometry.orientation(), tolerance: 6) {
            mismatchSince = nil
            return
        }
        // 位置不一致需持续一秒以上才移动指针，避免与应用栏的跟随换屏互相拉扯。
        if mismatchSince == nil { mismatchSince = now }
        let pointerAtTarget = DockMotionLayout.isAtEdge(NSEvent.mouseLocation, screen: target.frame, position: ShadowDockGeometry.orientation())
        guard pointerAtTarget || now - (mismatchSince ?? now) >= 1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.poll() }
            return
        }
        // 只在需要时轻推一次；多次失败后停止，避免反复挪动指针。
        guard relocationAttempts < 3, now - lastRelocation > 4, NSEvent.pressedMouseButtons == 0 else { return }
        let orientation = ShadowDockGeometry.orientation()
        // 指针已停在目标屏外露边缘（跟随指针换屏时）就地推，不移动指针；否则短暂移到外露边缘再放回。
        let pointer = NSEvent.mouseLocation
        let nearPoint = ShadowDockGeometry.exposedEdgePoint(on: target, orientation: orientation, near: pointer)
        let pointerOnEdge = DockMotionLayout.isAtEdge(pointer, screen: target.frame, position: orientation) && nearPoint != nil
        // 边缘点必须落在屏幕真正的边上：指针在容差内但离边几像素时，直接拿指针坐标推 Dock 会失败。
        guard let point = pointerOnEdge ? nearPoint : ShadowDockGeometry.exposedEdgePoint(on: target, orientation: orientation) else {
            lastError = "目标屏没有可用的外露边缘，系统 Dock 无法迁移。"
            return
        }
        lastRelocation = now
        relocationAttempts += 1
        // 指针只是“接近”边缘时，推完要放回原处；真正压在边上才不挪动。
        let restore = !(pointerOnEdge && hypot(pointer.x - point.x, pointer.y - point.y) < 0.5)
        Task.detached(priority: .userInitiated) { ShadowDockGeometry.push(at: point, orientation: orientation, restorePointer: restore) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.poll() }
    }

    private func updatePatch() {
        guard running, let frame = nativeFrame, frame.width > 0, frame.height > 0,
              let screen = screen(containing: frame) else {
            base.hide(); hideLabel()
            return
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let fullscreen = fullscreenDisplays.contains(displayID)
        // 补底只合成壁纸层，必须严格限制在系统占位区内，否则会盖住占位区外的窗口边缘。
        // 左右多留约一格半：系统 Dock 因启动、退出或最小化变宽时，下一次轮询前也不会露出。
        let full = screen.frame, usable = screen.visibleFrame
        let orientation = ShadowDockGeometry.orientation()
        let reserved: CGRect
        switch orientation {
        case .bottom: reserved = CGRect(x: full.minX, y: full.minY, width: full.width, height: usable.minY - full.minY)
        case .left: reserved = CGRect(x: full.minX, y: full.minY, width: usable.minX - full.minX, height: full.height)
        case .right: reserved = CGRect(x: usable.maxX, y: full.minY, width: full.maxX - usable.maxX, height: full.height)
        }
        // 补底只比系统 Dock 玻璃略大，藏在应用栏玻璃之下；左右放宽会在铺满窗口的阴影里露出亮块。
        let covered = frame.insetBy(dx: -3, dy: -10)
        let rect = fullscreen ? covered.intersection(full) : covered.intersection(reserved)
        guard rect.width > 1, rect.height > 1 else { base.hide(); hideLabel(); return }
        // 屏幕捕捉拿不到 WindowServer 合成的窗口阴影：按实测曲线把窗口投进 Dock 区域的阴影画回补底。
        // 窗口真正伸进占位区时，补底才连窗口内容一起截；贴在占位区上沿的铺满窗口不算。
        let shadows = fullscreen ? [] : casters
        let intruding = shadows.contains { $0.frame.minY < rect.maxY - 1 && $0.frame.intersection(rect).width > 1 }
        // 全屏时应用栏随指针唤出；补底提前持续捕捉，唤出瞬间就有画面，不会先露出纯色矩形。
        guard visible else {
            if fullscreen { base.prepare(rect: rect, screen: screen, includeApps: true, framesPerSecond: 10) } else { base.hide() }
            hideLabel()
            return
        }
        base.show(rect: rect, screen: screen, includeApps: fullscreen || intruding, interactive: true, framesPerSecond: 10)
        base.setShadows(shadows, region: rect, scale: 1)
        // 系统 Dock 的名称标签不受上层窗口遮挡影响，按指针直接弹出在 Dock 上方；
        // 悬停时在这一条上加实时画面（排除系统 Dock），不悬停时撤掉以免平时增加合成负担。
        // 图标区拦截生效后系统 Dock 不再冒名称标签，标签遮盖整块撤掉；拦截不可用时才退回遮盖。
        guard !edgeGuard.guardsDock, !menuOpen, hovering || near,
              ProcessInfo.processInfo.environment["DOCKFOLDERS_MEASURE_NO_LABEL"] != "1" else {
            hideLabel(); return
        }
        let strip: CGRect
        let labelSpan = frame.insetBy(dx: -100, dy: 0)
        switch orientation {
        case .bottom: strip = CGRect(x: labelSpan.minX, y: rect.maxY, width: labelSpan.width, height: 64)
        case .left: strip = CGRect(x: rect.maxX, y: frame.minY - 100, width: 64 + 160, height: frame.height + 200)
        case .right: strip = CGRect(x: rect.minX - 64 - 160, y: frame.minY - 100, width: 64 + 160, height: frame.height + 200)
        }
        let labelRect = strip.intersection(full)
        guard labelRect.width > 1, labelRect.height > 1 else { hideLabel(); return }
        // 窗口覆盖 Dock 上方一条，但遮罩平时全透明，只在系统 Dock 冒出名称标签的位置露出 6 fps 的捕捉画面，
        // 不再整条盖住上方界面（整条盖住时，条内外的动画不同步）。靠近时就显示，悬停瞬间已有画面。
        label.show(rect: labelRect, screen: screen, includeApps: true, interactive: false, framesPerSecond: 6, fullResolution: true)
        label.setShadows(shadows, region: labelRect, scale: screen.backingScaleFactor)
        labelRegion = labelRect
        startLabelMask()
    }

    private func startLabelMask() {
        updateLabelMask()
        guard labelTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateLabelMask() } }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer
    }

    private func hideLabel() {
        label.hide()
        stopLabelMask()
    }

    private func stopLabelMask() {
        labelTimer?.invalidate(); labelTimer = nil
        labelRegion = nil; currentLabel = nil; fadingLabels = []
    }

    /// 系统 Dock 只为指针下的那个图标显示名称：遮罩跟随这个图标，刚离开的图标再保留 0.5 秒盖住标签淡出。
    private func updateLabelMask() {
        guard let region = labelRegion else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pointer = NSEvent.mouseLocation
        let next = hoveredNativeTile(at: pointer).map { labelRect(for: $0, in: region) }
        if next != currentLabel {
            if let currentLabel { fadingLabels.append((currentLabel, now + 0.5)) }
            currentLabel = next
        }
        fadingLabels.removeAll { $0.until <= now || $0.rect == currentLabel }
        label.setVisibleRects((currentLabel.map { [$0] } ?? []) + fadingLabels.map(\.rect))
    }

    private func hoveredNativeTile(at point: CGPoint) -> NativeDockTile? {
        guard let frame = nativeFrame, frame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        switch ShadowDockGeometry.orientation() {
        case .bottom: return nativeTiles.first { $0.frame.minX <= point.x && point.x < $0.frame.maxX }
        case .left, .right: return nativeTiles.first { $0.frame.minY <= point.y && point.y < $0.frame.maxY }
        }
    }

    /// 系统名称标签：13 点字的玻璃胶囊，居中于图标上方（侧边 Dock 时在图标旁）；左右各多留 12 点。
    private func labelRect(for tile: NativeDockTile, in region: CGRect) -> CGRect {
        let textWidth = (tile.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let width = ceil(textWidth) + 26 + 24
        switch ShadowDockGeometry.orientation() {
        case .bottom:
            let x = min(max(tile.frame.midX - width / 2, region.minX), region.maxX - width)
            return CGRect(x: x, y: region.minY, width: width, height: region.height).intersection(region)
        case .left, .right:
            return CGRect(x: region.minX, y: tile.frame.midY - 24, width: region.width, height: 48).intersection(region)
        }
    }

    /// 窗口移动、缩放或切换前台 App 时阴影要跟上；窗口列表没变就不重画。
    /// 平时每 0.25 秒读一次窗口列表；Dock 附近有窗口且按住鼠标（可能在拖窗口），或刚检测到变化的 0.6 秒内，
    /// 每秒读 30 次，补底阴影跟着窗口走，减少拖动瞬间补底边缘与真实阴影错开。
    private func shadowTick() {
        guard running, visible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fast = now < fastShadowsUntil || (NSEvent.pressedMouseButtons & 1 != 0 && base.shadowCasterCount > 0)
        guard now - lastShadowScan >= (fast ? 0 : 0.25) else { return }
        refreshShadows()
    }

    private func refreshShadows() {
        guard running, !scanningShadows else { return }
        scanningShadows = true
        lastShadowScan = ProcessInfo.processInfo.systemUptime
        let own = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task.detached(priority: .utility) {
            let next = ShadowDockGeometry.shadowCasters(excluding: own, frontmost: frontmost)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanningShadows = false
                guard self.running, next != self.casters else { return }
                self.fastShadowsUntil = ProcessInfo.processInfo.systemUptime + 0.6
                self.casters = next
                self.updatePatch()
            }
        }
    }
}

struct NativeDockTile: Equatable, Sendable {
    var frame: CGRect
    var title: String
}

/// 一块实时补底：窗口 + 屏幕捕捉流，只在内存中合成。补底、标签遮盖与原生菜单遮盖共用。
@MainActor
final class ShadowPatch {
    private let title: String
    private let level: NSWindow.Level
    private var panel: NSPanel?
    private var layer: CALayer?
    private var stream: SCStream?
    private var output: ShadowStreamOutput?
    private var key: String?
    private var geometryKey: String?
    private var wantsVisible = false
    private var hasFrame = false
    private(set) var lastError: String?
    private var shadowLayer: CALayer?
    private var shadowKey: ShadowKey?
    /// 遮罩模式：窗口透明，只露出 `setVisibleRects` 指定的几块。
    private let masked: Bool
    private var maskLayer: CAShapeLayer?
    private var visibleRects: [CGRect]?
    private(set) var includesApps = false
    private(set) var shadowCasterCount = 0
    private(set) var hasActiveShadow = false
    var isVisible: Bool { panel?.isVisible == true }
    /// 正在显示时的屏幕位置。
    var visibleFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
    var isStreaming: Bool { stream != nil }

    private struct ShadowKey: Equatable {
        var region: CGRect
        var scale: CGFloat
        var casters: [WindowShadowCaster]
        var exclusions: [CGRect]
    }

    /// 非空时改用定时单帧截图（不持续录制）。当前补底和标签遮盖都使用实时流；
    /// 这个开关保留给需要极低负载、且能接受画面陈旧的场景。
    private let snapshotInterval: TimeInterval?
    private var snapshotTask: Task<Void, Never>?

    init(title: String, level: NSWindow.Level, snapshotInterval: TimeInterval? = nil, masked: Bool = false) {
        self.title = title; self.level = level; self.snapshotInterval = snapshotInterval; self.masked = masked
    }

    /// 屏幕坐标下要露出的区域；其余部分透明。
    func setVisibleRects(_ rects: [CGRect]) {
        guard let panel, let maskLayer, let layer else { return }
        // 遮罩每秒检查 30 次；区域没变就不提交，否则每次都会触发一轮全窗口布局。
        let local = rects.map { $0.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) }
        guard local != visibleRects || maskLayer.frame != layer.bounds else { return }
        visibleRects = local
        let path = CGMutablePath()
        for rect in local { path.addRect(rect) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if maskLayer.frame != layer.bounds { maskLayer.frame = layer.bounds }
        maskLayer.path = path
        CATransaction.commit()
    }

    func hide() {
        wantsVisible = false; hasFrame = false
        layer?.contents = nil
        shadowLayer?.contents = nil; shadowKey = nil
        maskLayer?.path = nil; visibleRects = nil
        panel?.orderOut(nil)
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; output = nil; key = nil; geometryKey = nil
        snapshotTask?.cancel(); snapshotTask = nil
    }

    /// `existingWindowsOnly`：盖在应用栏之上的原生菜单遮盖。截应用栏、补底与其它窗口，但不截这块遮盖、
    /// 系统 Dock 自己的窗口以及之后才出现的系统菜单（见下方过滤器的选择）。
    func show(rect: CGRect, screen: NSScreen, includeApps: Bool, interactive: Bool, framesPerSecond: Int32,
              fullResolution: Bool = false, existingWindowsOnly: Bool = false) {
        let panel = self.panel ?? make()
        panel.ignoresMouseEvents = !interactive
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        wantsVisible = true
        startStream(rect: rect, screen: screen, includeApps: includeApps, framesPerSecond: framesPerSecond,
                    fullResolution: fullResolution, existingWindowsOnly: existingWindowsOnly)
        // 新流的第一帧到达前不上屏，避免露出纯色底。
        if hasFrame, !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 只预热捕捉，不显示窗口。
    func prepare(rect: CGRect, screen: NSScreen, includeApps: Bool, framesPerSecond: Int32, fullResolution: Bool = false) {
        let panel = self.panel ?? make()
        wantsVisible = false
        panel.orderOut(nil)
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        startStream(rect: rect, screen: screen, includeApps: includeApps, framesPerSecond: framesPerSecond,
                    fullResolution: fullResolution, existingWindowsOnly: false)
    }

    /// 等新流的第一帧上屏（遮盖真正盖住之后才能做被它遮住的事）。超时返回 false。
    func waitForFirstFrame(timeout: TimeInterval) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if hasFrame, panel?.isVisible == true { return true }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return false
    }

    /// 在捕捉画面之上叠窗口阴影；`region` 与补底窗口同一块屏幕区域。窗口和区域都没变时不重画。
    func setShadows(_ casters: [WindowShadowCaster], region: CGRect, scale: CGFloat, exclusions: [CGRect] = []) {
        guard let shadowLayer else { return }
        let relevant = WindowShadowRenderer.relevant(casters, in: region)
        let key = ShadowKey(region: region, scale: scale, casters: relevant, exclusions: exclusions)
        guard key != shadowKey else { return }
        shadowKey = key
        shadowCasterCount = relevant.count
        hasActiveShadow = relevant.contains(where: \.active)
        shadowLayer.frame = CGRect(origin: .zero, size: region.size)
        shadowLayer.contents = relevant.isEmpty ? nil
            : Self.shadowImage(WindowShadowRenderer.alphaMap(region: region, scale: Double(scale), casters: relevant, exclusions: exclusions))
    }

    /// 直接使用已算好的阴影图（调用方在后台线程算，避免大区域卡主线程）。
    func setShadowMap(_ map: (width: Int, height: Int, alpha: [UInt8]), region: CGRect) {
        guard let shadowLayer else { return }
        shadowKey = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadowLayer.frame = CGRect(origin: .zero, size: region.size)
        shadowLayer.contents = map.alpha.contains(where: { $0 > 0 }) ? Self.shadowImage(map) : nil
        CATransaction.commit()
    }

    /// 黑色 + 逐像素 alpha，第一行对应区域顶边。
    private static func shadowImage(_ map: (width: Int, height: Int, alpha: [UInt8])) -> CGImage? {
        guard map.width > 0, map.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: map.width * map.height * 4)
        for (index, value) in map.alpha.enumerated() { pixels[index * 4 + 3] = value }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: map.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func receive(_ surface: Any, key frameKey: String) {
        guard frameKey == key else { return }
        layer?.contents = surface
        hasFrame = true
        if wantsVisible, let panel, !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        // 补底背景必须不透明：透明像素会让鼠标穿透到下方系统 Dock。遮罩模式不接收鼠标，可以透明。
        if masked { panel.isOpaque = false; panel.backgroundColor = .clear } else { panel.isOpaque = true; panel.backgroundColor = .black }
        panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.title = title
        panel.setAccessibilityElement(false)
        // 补底位于应用栏下方；必须产生鼠标移动事件，应用栏的本地监听才能立即感知指针进入并放大。
        let view = ShadowPatchView()
        view.wantsLayer = true
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer = layer
        let shadow = CALayer()
        shadow.contentsGravity = .resize
        shadow.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(shadow)
        if masked {
            let mask = CAShapeLayer()
            mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.mask = mask
            maskLayer = mask
        }
        panel.contentView = view
        self.panel = panel; self.layer = layer; self.shadowLayer = shadow
        return panel
    }

    private func startStream(rect: CGRect, screen: NSScreen, includeApps: Bool, framesPerSecond: Int32,
                             fullResolution: Bool, existingWindowsOnly: Bool) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let displayID = number.uint32Value
        // SCK 的源矩形以显示器左上为原点。
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        // 帧率和分辨率也进入 key：悬停与预热切换参数时必须重建流，否则会沿用旧流。
        let geometry = "\(displayID)|\(NSStringFromRect(local))|\(includeApps)|\(fullResolution)|\(existingWindowsOnly)"
        let wanted = "\(geometry)|\(framesPerSecond)"
        includesApps = includeApps
        if key == wanted { return }
        let geometryChanged = geometryKey != geometry
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; output = nil; key = wanted; geometryKey = geometry
        snapshotTask?.cancel(); snapshotTask = nil
        // 只切换帧率时保留上一帧：悬停瞬间先显示低帧率预热画面，等新流第一帧到达再替换，避免露出系统标签。
        // 几何变化时也不清空旧画面：新流首帧到达前窗口保持旧内容，短暂错位好过闪黑。
        if geometryChanged { hasFrame = false }
        let snapshotInterval = self.snapshotInterval
        let screenColorSpaceName = screen.colorSpace?.cgColorSpace?.name
        let scale = fullResolution ? screen.backingScaleFactor : 1
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let selfWindowID = CGWindowID(panel?.windowNumber ?? 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let filter: SCContentFilter
                if existingWindowsOnly {
                    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
                    // 画系统菜单的 DockHelper 按需启动：在运行时按应用排除（新流约 0.13 秒起来），
                    // 不在运行时它随后画出的菜单会被截进遮盖，只能改为只截已有窗口（约 0.55 秒）。
                    if let helper = content.applications.first(where: { $0.applicationName == "DockHelper" }) {
                        let excludedApps = content.applications.filter { app in
                            app.processID == ownPID || app.processID == helper.processID || app.bundleIdentifier.hasPrefix("com.apple.dock")
                        }
                        let kept = content.windows.filter { window in
                            (window.owningApplication?.bundleIdentifier == "com.apple.dock" && window.windowLayer < dockLevel)
                                || (window.owningApplication?.processID == ownPID && window.windowID != selfWindowID)
                        }
                        filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: kept)
                    } else {
                        let sourceGlobal = CGRect(x: local.minX + CGFloat(display.frame.minX), y: local.minY + CGFloat(display.frame.minY),
                                                  width: local.width, height: local.height)
                        let windows = content.windows.filter { window in
                            let owner = window.owningApplication
                            if window.windowID == selfWindowID || !window.frame.intersects(sourceGlobal) { return false }
                            // 系统 Dock 只保留壁纸、桌面层；它自己的 Dock 窗口和菜单都不截。
                            if owner?.bundleIdentifier == "com.apple.dock" { return window.windowLayer < dockLevel }
                            return true
                        }
                        filter = SCContentFilter(display: display, including: windows)
                    }
                } else if includeApps {
                    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
                    // 按应用整体排除本应用、系统 Dock 与 DockHelper（名称标签、菜单）——包括之后才出现的窗口；
                    // 只按当时可见窗口排除会把后来出现的遮盖层和标签拍进画面，形成自我叠加的残影。
                    // 系统 Dock 自己的壁纸/桌面层窗口仍需保留。
                    let excludedApps = content.applications.filter { app in
                        app.processID == ownPID || app.applicationName == "DockHelper" || app.bundleIdentifier.hasPrefix("com.apple.dock")
                    }
                    let kept = content.windows.filter { window in
                        window.owningApplication?.bundleIdentifier == "com.apple.dock" && window.windowLayer < dockLevel
                    }
                    filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: kept)
                } else {
                    // 只合成壁纸与桌面层窗口：系统占位区内正常不会有应用窗口，且整屏合成会明显加重 WindowServer。
                    let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
                    let included = content.windows.filter { window in
                        window.windowLayer <= desktopLevel && window.owningApplication?.processID != ownPID
                    }
                    filter = SCContentFilter(display: display, including: included)
                }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = local
                // 补底位于玻璃之下或只是背景，按 1x 采样即可。
                configuration.width = Int(local.width * scale); configuration.height = Int(local.height * scale)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                if let name = screenColorSpaceName { configuration.colorSpaceName = name }
                if let snapshotInterval {
                    let task = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                                guard let self, self.key == wanted, !Task.isCancelled else { return }
                                self.receive(image, key: wanted)
                            }
                            try? await Task.sleep(for: .seconds(snapshotInterval))
                        }
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.key == wanted else { task.cancel(); return }
                        self.snapshotTask = task; self.lastError = nil
                    }
                    return
                }
                let output = ShadowStreamOutput { [weak self] surface in
                    Task { @MainActor [weak self] in self?.receive(surface, key: wanted) }
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                await MainActor.run { [weak self] in
                    guard let self, self.key == wanted else { Task { try? await stream.stopCapture() }; return }
                    self.stream = stream; self.output = output; self.lastError = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "补底捕捉失败：\(error.localizedDescription)"
                    if self?.key == wanted { self?.key = nil }
                }
            }
        }
    }
}

private final class ShadowPatchView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {}
}

private final class ShadowStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "io.daliang.dockfolders.shadow-patch", qos: .userInteractive)
    private let deliver: @Sendable (IOSurface) -> Void
    init(deliver: @escaping @Sendable (IOSurface) -> Void) { self.deliver = deliver }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        // 图层按 IOSurface 自带的色彩空间合成；未标注时会按错误色域显示，补底与周围壁纸出现色差。
        if let space = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, nil) {
            let colorSpace = space as! CGColorSpace
            if let list = colorSpace.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, list) }
        }
        deliver(unsafeBitCast(surface, to: IOSurface.self))
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

enum ShadowDockGeometry {
    /// 系统 Dock 栏的 AXList 矩形，转换为 AppKit 坐标。只读。
    /// 系统 Dock 外框和各图标（AppKit 坐标）。名称标签只为有标题的图标出现，间隔块不计入。
    static func readNativeDock() -> (frame: CGRect, tiles: [NativeDockTile])? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        func frame(of element: AXUIElement) -> CGRect? {
            guard let positionValue = value(element, kAXPositionAttribute), let sizeValue = value(element, kAXSizeAttribute) else { return nil }
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            guard size.width > 1, size.height > 1 else { return nil }
            return CGRect(x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width, height: size.height)
        }
        guard let children = value(app, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { (value($0, kAXRoleAttribute) as? String) == "AXList" }),
              let listFrame = frame(of: list) else { return nil }
        let tiles = (value(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).compactMap { item -> NativeDockTile? in
            guard let title = value(item, kAXTitleAttribute) as? String, !title.isEmpty, let tileFrame = frame(of: item) else { return nil }
            return NativeDockTile(frame: tileFrame, title: title)
        }
        return (listFrame, tiles)
    }


    /// 屏上普通应用窗口（AppKit 坐标），按前后顺序。当前 App 最前面的窗口用活跃阴影，其余用非活跃阴影。
    /// 读窗口列表在负载高时要几毫秒，调用方放在后台线程；前台 App 由主线程读好传入。
    static func shadowCasters(excluding pid: pid_t, frontmost: pid_t?) -> [WindowShadowCaster] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var activeAssigned = false
        var casters: [WindowShadowCaster] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner != pid,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  cg.width > 40, cg.height > 40 else { continue }
            let active = !activeAssigned && owner == frontmost
            if active { activeAssigned = true }
            casters.append(WindowShadowCaster(frame: CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height), active: active))
        }
        return casters
    }

    /// 系统 Dock 主窗口的中心（AppKit 坐标；藏着时读不到辅助功能外框，窗口也标为不在屏上，但位置仍指向所在屏）。
    /// 要取全系统窗口列表，负载高时上百毫秒（10-23 卡顿栈里在主线程 13 次共约 2.2 秒），调用方放在后台线程。
    static func dockWindowCenter() -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        for window in list where (window[kCGWindowOwnerName as String] as? String).map({ ["Dock", "程序坞"].contains($0) }) == true
            && (window[kCGWindowLayer as String] as? Int) == dockLevel {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            return CGPoint(x: cg.midX, y: primaryHeight - cg.midY)
        }
        return nil
    }

    @MainActor static func screen(containing point: CGPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func orientation() -> DockPosition {
        switch CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }

    /// 目标屏对应边上不与其他屏相接的一段，返回其中点（AppKit 坐标）。
    static func exposedEdgePoint(on screen: NSScreen, orientation: DockPosition, near pointer: CGPoint? = nil) -> CGPoint? {
        let frame = screen.frame
        let others = NSScreen.screens.map(\.frame).filter { $0 != frame }
        var segments: [ClosedRange<CGFloat>]
        switch orientation {
        case .bottom: segments = [frame.minX...frame.maxX]
        case .left, .right: segments = [frame.minY...frame.maxY]
        }
        for other in others {
            let blocked: ClosedRange<CGFloat>?
            switch orientation {
            case .bottom: blocked = abs(other.maxY - frame.minY) < 1 ? max(other.minX, frame.minX)...max(min(other.maxX, frame.maxX), max(other.minX, frame.minX)) : nil
            case .left: blocked = abs(other.maxX - frame.minX) < 1 ? max(other.minY, frame.minY)...max(min(other.maxY, frame.maxY), max(other.minY, frame.minY)) : nil
            case .right: blocked = abs(other.minX - frame.maxX) < 1 ? max(other.minY, frame.minY)...max(min(other.maxY, frame.maxY), max(other.minY, frame.minY)) : nil
            }
            guard let blocked, blocked.upperBound > blocked.lowerBound else { continue }
            segments = segments.flatMap { segment -> [ClosedRange<CGFloat>] in
                guard blocked.overlaps(segment) else { return [segment] }
                var parts: [ClosedRange<CGFloat>] = []
                if blocked.lowerBound > segment.lowerBound { parts.append(segment.lowerBound...blocked.lowerBound) }
                if blocked.upperBound < segment.upperBound { parts.append(blocked.upperBound...segment.upperBound) }
                return parts
            }
        }
        let usable = segments.filter { $0.upperBound - $0.lowerBound >= 40 }
        if let pointer {
            let axis = orientation == .bottom ? pointer.x : pointer.y
            guard usable.contains(where: { $0.contains(axis) }) else { return nil }
            switch orientation {
            case .bottom: return CGPoint(x: pointer.x, y: frame.minY)
            case .left: return CGPoint(x: frame.minX, y: pointer.y)
            case .right: return CGPoint(x: frame.maxX - 1, y: pointer.y)
            }
        }
        guard let best = usable.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return nil }
        let middle = (best.lowerBound + best.upperBound) / 2
        switch orientation {
        case .bottom: return CGPoint(x: middle, y: frame.minY)
        case .left: return CGPoint(x: frame.minX, y: middle)
        case .right: return CGPoint(x: frame.maxX - 1, y: middle)
        }
    }

    /// 在边缘外侧持续推指针，让系统 Dock 按原生规则迁移到该屏，随后把指针放回原处。
    static func push(at point: CGPoint, orientation: DockPosition, restorePointer: Bool, count: Int = 40) {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartz = CGPoint(x: point.x, y: orientation == .bottom ? primaryHeight - point.y - 1 : primaryHeight - point.y)
        let original = CGEvent(source: nil)?.location
        for index in 0..<count {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition:
                    CGPoint(x: quartz.x + CGFloat(index % 2), y: quartz.y), mouseButton: .left) else { continue }
            switch orientation {
            case .bottom: event.setIntegerValueField(.mouseEventDeltaY, value: 8)
            case .left: event.setIntegerValueField(.mouseEventDeltaX, value: -8)
            case .right: event.setIntegerValueField(.mouseEventDeltaX, value: 8)
            }
            event.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        if restorePointer, let original { CGWarpMouseCursorPosition(original); CGAssociateMouseAndMouseCursorPosition(1) }
    }
}

/// 系统 Dock 图标尺寸的即时读写：CoreDock 私有接口，取值为 (尺寸 - 16) / 112，不重启 Dock。
/// 系统按向下取整生效（34 会成 33），写入时补一点余量。改完系统 Dock 会弹出来，调用方要随即重新开启自动隐藏。
enum CoreDockTileSize {
    private typealias Getter = @convention(c) () -> Float
    private typealias Setter = @convention(c) (Float) -> Void

    static func get() -> Double? {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CoreDockGetTileSize") else { return nil }
        return 16 + Double(unsafeBitCast(symbol, to: Getter.self)()) * 112
    }

    @discardableResult
    static func set(_ size: Double) -> Bool {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CoreDockSetTileSize") else { return false }
        unsafeBitCast(symbol, to: Setter.self)(Float((min(max(size, 16), 128) - 16 + 0.01) / 112))
        return true
    }
}

/// 系统 Dock 自动隐藏的即时开关：CoreDock 私有接口（系统偏好里的开关同样走它），不重启 Dock。
enum CoreDockAutoHide {
    private typealias Setter = @convention(c) (UInt8) -> Void
    /// 找不到接口时返回 false。
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CoreDockSetAutoHideEnabled") else { return false }
        unsafeBitCast(symbol, to: Setter.self)(enabled ? 1 : 0)
        return true
    }
}
