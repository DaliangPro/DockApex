import AppKit
import CoreGraphics

/// 让被应用栏盖住的系统 Dock 感知不到指针：丢弃两类区域内的鼠标移动事件，光标本身照常移动，点击与拖动不受影响。
/// - 推边区：固定显示屏时其它屏 Dock 所在边的几像素。macOS 靠指针压边并继续推来挪 Dock，收不到就不挪（参考开源工具 DockAnchor）。
/// - 图标区：系统 Dock 自己的图标范围。系统 Dock 收不到移动就不会冒名称标签，不必再用截屏画面去盖。
///   被拦下的事件不会更新应用读到的指针位置，应用栏改用这里记下的真实位置（`takeDockLocation`）。
/// 事件监听放在独立线程的 run loop 上：主线程卡顿时不会拖慢全系统的鼠标。
final class DockEdgeGuard: @unchecked Sendable {
    private let lock = NSLock()
    /// Quartz 全局坐标（左上为原点）。
    private var zones: [CGRect] = []
    private var dockZones: [CGRect] = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var blocked = 0
    private var dockBlocked = 0
    private var pendingDockLocation: CGPoint?
    private let onDockMove: @Sendable () -> Void

    init(onDockMove: @escaping @Sendable () -> Void) { self.onDockMove = onDockMove }

    var summary: [String: Any] {
        lock.withLock { ["active": tap != nil, "zones": zones.count, "dockZones": dockZones.count,
                         "blockedEvents": blocked, "dockBlockedEvents": dockBlocked] }
    }

    /// 系统 Dock 图标区确实在拦截（监听已建立）。拦截不可用时调用方退回用标签遮盖。
    var guardsDock: Bool { lock.withLock { tap != nil && !dockZones.isEmpty } }

    /// 两类区域都为空即停止监听。
    func setZones(edges: [CGRect], dock: [CGRect]) {
        let changed = lock.withLock { () -> Bool in
            guard zones != edges || dockZones != dock else { return false }
            zones = edges; dockZones = dock
            return true
        }
        guard changed else { return }
        if edges.isEmpty && dock.isEmpty { stop() } else { start() }
    }

    func stop() {
        let (tap, loop) = lock.withLock { (self.tap, self.runLoop) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    private func start() {
        let needsThread = lock.withLock { () -> Bool in
            guard thread == nil else { return false }
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "io.daliang.dockfolders.edge-guard"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            return true
        }
        if needsThread { lock.withLock { thread }?.start() }
    }

    private func run() {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: dockEdgeGuardCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            lock.withLock { thread = nil }
            return
        }
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let shouldRun = lock.withLock { () -> Bool in
            self.tap = tap; self.runLoop = loop
            return !zones.isEmpty || !dockZones.isEmpty
        }
        if shouldRun { CFRunLoopRun() }
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
        let restart = lock.withLock { () -> Bool in
            self.tap = nil; self.runLoop = nil; self.thread = nil
            return !zones.isEmpty || !dockZones.isEmpty
        }
        // 停止与重新设置区域交错时，以最新区域为准。
        if restart { start() }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let location = event.location
        var notify = false
        let block = lock.withLock { () -> Bool in
            if zones.contains(where: { $0.contains(location) }) { blocked += 1; return true }
            guard dockZones.contains(where: { $0.contains(location) }) else { return false }
            dockBlocked += 1
            // 只保留最新位置；主线程取走之前不重复通知，高回报率鼠标也只排一个主线程任务。
            notify = pendingDockLocation == nil
            pendingDockLocation = location
            return true
        }
        if notify { onDockMove() }
        return block ? nil : Unmanaged.passUnretained(event)
    }

    /// 取走最近一次在图标区被拦下的指针位置（Quartz 坐标）。
    func takeDockLocation() -> CGPoint? {
        lock.withLock {
            defer { pendingDockLocation = nil }
            return pendingDockLocation
        }
    }

    /// 系统 Dock 图标区（Quartz 坐标）：从屏幕底边到图标区上沿，横跨整块屏。只处理底部 Dock。
    /// 系统 Dock 随 App 启动、退出变宽，按当时宽度拦截会在边缘漏进事件，标签漏出后收不到离开事件会一直停着。
    static func dockZone(nativeFrame frame: CGRect, on screen: NSScreen) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let top = frame.maxY + 2, bottom = screen.frame.minY
        return CGRect(x: screen.frame.minX, y: primaryHeight - top, width: screen.frame.width, height: top - bottom)
    }

    /// 各屏 Dock 所在边的拦截带（Quartz 坐标）。目标屏不拦截，为 nil 时各屏都拦；`depth` 为带宽。
    static func zones(excluding target: NSScreen?, orientation: DockPosition, depth: CGFloat = 6) -> [CGRect] {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.filter { $0 != target }.map { screen in
            let frame = screen.frame
            let top = primaryHeight - frame.maxY
            switch orientation {
            case .bottom: return CGRect(x: frame.minX, y: primaryHeight - frame.minY - depth, width: frame.width, height: depth)
            case .left: return CGRect(x: frame.minX, y: top, width: depth, height: frame.height)
            case .right: return CGRect(x: frame.maxX - depth, y: top, width: depth, height: frame.height)
            }
        }
    }
}

private func dockEdgeGuardCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<DockEdgeGuard>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
