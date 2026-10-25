import AppKit
import ApplicationServices

/// 悬浮条避让：已运行的 App（尤其语音输入条这类辅助程序的浮窗）读不到应用栏占位，会按“底部没有 Dock”摆放，
/// 伸进应用栏。系统只认系统 Dock 的广播，隐藏时它总广播 0，先后启动都会丢占位，只能把窗口挪开。
/// 监听第三方程序的窗口出现、移动、改尺寸事件，事件一到立即检查（每 0.5 秒的轮询作兜底），
/// 伸进应用栏的小浮窗用辅助功能整体挪开一个占位厚度（保留它原本离边的间距）。
/// 不动：本应用与苹果系统进程的窗口、辅助功能里不是窗口或不让挪的、按着鼠标时（可能正在拖它）、
/// 真实位置尺寸与屏上边框对不上的（最小化或恢复的神灯动画中，屏上边框是贴着底边的小框）。
/// 挪开后 1.5 秒内又被挪回来算一次较劲，两次后放手，直到这个窗口关掉或被收起再出现。
final class DockFloatingAvoidance: @unchecked Sendable {
    struct Report: Sendable { var moved = 0; var released = 0; var lastApp = "" }
    private enum MoveResult { case moved, failed, animating }

    private struct Tracked {
        var movedAt: TimeInterval?
        var fights = 0
        var failures = 0
        var released = false
        /// 上次真实位置尺寸对不上时的屏上边框。
        var mismatch: CGRect?
    }

    private let queue = DispatchQueue(label: "io.daliang.dockfolders.floating-avoidance", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var zones: [DockWorkAreaZone] = []
    private var tracked: [CGWindowID: Tracked] = [:]
    private var bundleIDs: [pid_t: String] = [:]
    /// 统计单独加锁：主线程写诊断时直接读，不等后台扫描（扫描里的辅助功能调用可能要几百毫秒）。
    private let reportLock = NSLock()
    private var report = Report()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let onMove: @Sendable (String, CGFloat) -> Void

    /// 辅助功能事件在独立线程的 run loop 上接收，不经过主线程。
    private var observerThread: Thread?
    private var observerLoop: CFRunLoop?
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var scanQueued = false
    private var forwardQueued = false
    /// 应用栏在动时把扫描往后推：取窗口列表要先等 WindowServer 处理完本应用刚提交的界面改动，等的时候一直占着
    /// 窗口服务连接锁，主线程下一次提交界面只能干等（10-25 卡顿栈：拖设置菜单滑块时主线程卡 0.51 秒，占锁的正是这里）。
    /// 悬停期间一直推，刷新应用栏后推 0.5 秒；伸进应用栏的浮窗因此最多晚半秒挪开。
    private let holdLock = NSLock()
    private var heldWhileHovering = false
    private var heldUntil: TimeInterval = 0
    /// 窗口事件同时转给大窗口避让（在主线程调用，最多每 30 毫秒一次），不必等窗口缓存刷新。
    var onWindowEvent: (@MainActor () -> Void)?

    init(onMove: @escaping @Sendable (String, CGFloat) -> Void) { self.onMove = onMove }

    /// 开始监听窗口事件（只调用一次）；占位区为空时事件到了也不做事。
    @MainActor
    func startObserving() {
        guard observerThread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.observerLoop = CFRunLoopGetCurrent()
            ready.signal()
            // run loop 没有输入源会立即返回；挂一个永不触发的计时器保持运行。
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "io.daliang.dockfolders.floating-observers"
        thread.qualityOfService = .userInteractive
        observerThread = thread
        thread.start()
        ready.wait()
        for app in NSWorkspace.shared.runningApplications { watch(app) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.watch(app) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier { self?.unwatch(pid) }
        })
    }

    /// 第三方的普通与辅助程序（语音条等多属后者）；本应用与苹果系统进程不监听。
    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ownPID, app.activationPolicy != .prohibited, app.bundleIdentifier?.hasPrefix("com.apple.") != true,
              let loop = observerLoop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self, self.observers[pid] == nil else { return }
            var observer: AXObserver?
            guard AXObserverCreate(pid, dockFloatingObserverCallback, &observer) == .success, let observer else { return }
            let element = AXUIElementCreateApplication(pid)
            let context = Unmanaged.passUnretained(self).toOpaque()
            var registered = 0
            for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
                if AXObserverAddNotification(observer, element, name as CFString, context) == .success { registered += 1 }
            }
            guard registered > 0 else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.observers[pid] = observer
        }
        CFRunLoopWakeUp(loop)
    }

    private func unwatch(_ pid: pid_t) {
        guard let loop = observerLoop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let observer = self?.observers.removeValue(forKey: pid) else { return }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        CFRunLoopWakeUp(loop)
    }

    /// 窗口事件：合并成一次立即检查。
    fileprivate func windowEvent() {
        queue.async { [self] in
            if !scanQueued {
                scanQueued = true
                queue.async { [self] in scanQueued = false; scan() }
            }
            guard !forwardQueued else { return }
            forwardQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                queue.async { [self] in forwardQueued = false }
                MainActor.assumeIsolated { onWindowEvent?() }
            }
        }
    }

    var summary: Report { reportLock.withLock { report } }

    func holdScans(for seconds: TimeInterval) {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        holdLock.withLock { heldUntil = max(heldUntil, until) }
    }

    /// 指针在应用栏上（悬停放大一直在提交界面）时暂停扫描，离开后再等 0.5 秒放大收回。
    func setHeldWhileHovering(_ held: Bool) {
        holdLock.withLock { heldWhileHovering = held }
        if !held { holdScans(for: 0.5) }
    }

    /// 还要等多久才能扫；nil 表示现在就能扫。
    private var holdRemaining: TimeInterval? {
        holdLock.withLock {
            if heldWhileHovering { return 0.3 }
            let remaining = heldUntil - ProcessInfo.processInfo.systemUptime
            return remaining > 0 ? remaining : nil
        }
    }

    /// 占位区为空即停止扫描。
    func update(zones: [DockWorkAreaZone]) {
        queue.async { [self] in
            self.zones = zones
            if zones.isEmpty { timer?.cancel(); timer = nil; return }
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() { update(zones: []) }

    private func scan() {
        if let wait = holdRemaining {
            if !scanQueued {
                scanQueued = true
                queue.asyncAfter(deadline: .now() + wait) { [self] in scanQueued = false; scan() }
            }
            return
        }
        guard !zones.isEmpty, AXIsProcessTrusted(),
              CGEventSource.buttonState(.combinedSessionState, button: .left) == false,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let now = ProcessInfo.processInfo.systemUptime
        var seen = Set<CGWindowID>()
        for info in list {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0, layer < 1000,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { continue }
            seen.insert(number)
            let frame = CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            guard let target = DockWorkAreaGeometry.floatingAdjustment(frame, zones: zones), !isSystem(pid) else { continue }
            var state = tracked[number] ?? Tracked()
            guard !state.released else { continue }
            if let movedAt = state.movedAt, now - movedAt < 1.5 {
                state.fights += 1
                if state.fights >= 2 { state.released = true; reportLock.withLock { report.released += 1 }; tracked[number] = state; continue }
            }
            let result = move(pid: pid, window: number, frame: frame, to: target, primaryHeight: primaryHeight)
            // 动画中的边框不是窗口真实位置，按它算出的新位置会把窗口挪错；这次不动，也不算失败。
            // 边框停着不动却仍对不上的不是动画，按失败计。
            if result == .animating, state.mismatch != frame { state.mismatch = frame; tracked[number] = state; continue }
            // 找不到对应窗口或不让挪：刚出现时可能还没就绪，连续三次不行就放手，免得每 0.5 秒白问一次。
            guard result == .moved else {
                state.failures += 1
                if state.failures >= 3 { state.released = true; reportLock.withLock { report.released += 1 } }
                tracked[number] = state
                continue
            }
            state.movedAt = now
            tracked[number] = state
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            reportLock.withLock { report.moved += 1; report.lastApp = name }
            onMove(name, max(abs(target.y - frame.minY), abs(target.x - frame.minX)))
        }
        // 收起或关掉的窗口重新出现时从头算。
        tracked = tracked.filter { seen.contains($0.key) }
    }

    private func isSystem(_ pid: pid_t) -> Bool {
        if bundleIDs[pid] == nil { bundleIDs[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
        if bundleIDs.count > 512 { bundleIDs.removeAll() }
        return bundleIDs[pid]?.hasPrefix("com.apple.") == true
    }

    /// 在 App 的辅助功能窗口里按窗口编号找到这个浮窗，真实位置尺寸与屏上边框一致、可挪才挪，写后读回核对。
    private func move(pid: pid_t, window number: CGWindowID, frame: CGRect, to target: CGPoint, primaryHeight: CGFloat) -> MoveResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement],
              let element = windows.first(where: { Self.windowNumber($0) == number }) else { return .failed }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              (role as? String) == kAXWindowRole else { return .failed }
        guard let position = Self.position(element), let size = Self.size(element) else { return .failed }
        let actual = CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
        guard abs(actual.minX - frame.minX) < 2, abs(actual.minY - frame.minY) < 2,
              abs(actual.width - frame.width) < 2, abs(actual.height - frame.height) < 2 else { return .animating }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success, settable.boolValue else { return .failed }
        var point = CGPoint(x: target.x, y: primaryHeight - target.y - frame.height)
        guard let value = AXValueCreate(.cgPoint, &point),
              AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success,
              let moved = Self.position(element) else { return .failed }
        return abs(moved.x - point.x) < 2 && abs(moved.y - point.y) < 2 ? .moved : .failed
    }

    private static func position(_ element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &result) ? result : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &result) ? result : nil
    }

    /// 辅助功能窗口对应的窗口编号；大窗口避让也用它对上屏上窗口列表。
    static func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        typealias Getter = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var number: CGWindowID = 0
        guard unsafeBitCast(symbol, to: Getter.self)(element, &number) == 0, number != 0 else { return nil }
        return number
    }
}

private func dockFloatingObserverCallback(observer: AXObserver, element: AXUIElement, notification: CFString,
                                          refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<DockFloatingAvoidance>.fromOpaque(refcon).takeUnretainedValue().windowEvent()
}
