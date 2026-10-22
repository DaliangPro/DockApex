import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// 先筛选当前各屏可见的整屏/硬件安全区窗口，再在后台读取对应窗口的 AXFullScreen。
/// 不读取窗口名称、不控制其他应用，也不把普通最大化窗口误当成真正全屏。
@MainActor
final class FullscreenTracker {
    private let onChanged: (Set<UInt32>) -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var latest: Set<UInt32> = []
    var activeDisplayIDs: [UInt32] { latest.sorted() }
    private var sampling: Task<Void, Never>?
    private var samplingWorker: Task<FullscreenWindowSample?, Never>?
    private var generation: UInt64 = 0
    private var needsResample = false
    init(onChanged: @escaping (Set<UInt32>) -> Void) { self.onChanged = onChanged }
    func start() {
        guard timer == nil else { return }
        generation &+= 1
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sample() }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        timer.tolerance = 0.1; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        sample()
    }
    func stop() {
        generation &+= 1
        timer?.invalidate(); timer = nil
        sampling?.cancel(); sampling = nil; needsResample = false
        samplingWorker?.cancel(); samplingWorker = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if !latest.isEmpty { latest = []; onChanged([]) }
    }
    private func sample() {
        guard timer != nil else { return }
        guard sampling == nil else { needsResample = true; return }
        let revision = generation
        let screens = Self.displayGeometry()
        // WindowServer 查询可能等待跨进程回复，不能占用悬停/拖动共用的主线程。
        let worker = Task.detached(priority: .utility) { FullscreenWindowReader.sample(displays: screens) }
        samplingWorker = worker
        sampling = Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self, !Task.isCancelled, self.generation == revision, self.timer != nil else { return }
            self.sampling = nil
            self.samplingWorker = nil
            // 采样期间发生空间/屏幕变化时重新读取，不发布过期布局。
            if self.needsResample { self.needsResample = false; self.sample(); return }
            guard let result else { return }
            // 短暂超时只保留此前已确认且当前仍有可见候选的屏幕，不把未知窗口提升为全屏。
            let matching = result.confirmedDisplayIDs.union(self.latest.intersection(result.unresolvedDisplayIDs))
            if matching != self.latest { self.latest = matching; self.onChanged(matching) }
        }
    }

    static func displayGeometry() -> [DockFullscreenGeometry.Display] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height)
            let inset = screen.safeAreaInsets
            let safe = CGRect(x: frame.minX + inset.left, y: frame.minY + inset.top,
                              width: frame.width - inset.left - inset.right, height: frame.height - inset.top - inset.bottom)
            return .init(id: id, frame: frame, safeFrame: safe)
        }
    }
}

struct FullscreenWindowSample: Sendable {
    var confirmedDisplayIDs = Set<UInt32>()
    var unresolvedDisplayIDs = Set<UInt32>()
    var candidateWindowCount = 0
    var queriedProcessCount = 0
    var queriedWindowCount = 0
    var elapsedMilliseconds: Double = 0
    var budgetExhausted = false
    var hasAccessibilityPermission = false
}

/// 所有 AX 对象都在本次后台调用内创建和释放；只返回可发送的数值结果。
enum FullscreenWindowReader {
    private struct Candidate {
        let pid: pid_t
        let number: CGWindowID
        let frame: CGRect
        let displayIDs: Set<UInt32>
    }

    static func sample(displays: [DockFullscreenGeometry.Display], budget: TimeInterval = 0.22) -> FullscreenWindowSample? {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + max(0, budget)
        guard !Task.isCancelled,
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = records.compactMap { record -> Candidate? in
            guard let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  let number = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let displayIDs = DockFullscreenGeometry.candidateDisplays(window: frame, displays: displays)
            return displayIDs.isEmpty ? nil : Candidate(pid: pid, number: number, frame: frame, displayIDs: displayIDs)
        }
        var result = FullscreenWindowSample()
        result.candidateWindowCount = candidates.count
        result.hasAccessibilityPermission = AXIsProcessTrusted()
        // 无权限时不请求授权、不猜测全屏。已有状态由本轮明确空集合清除。
        guard result.hasAccessibilityPermission else { return result }
        var remaining = Dictionary(candidates.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<pid_t>()
        for candidate in candidates where visited.insert(candidate.pid).inserted {
            guard permitted(deadline) else { break }
            let application = AXUIElementCreateApplication(candidate.pid)
            guard setTimeout(application, deadline: deadline) else { break }
            result.queriedProcessCount += 1
            var raw: CFArray?
            // 有界读取；无法匹配的候选保持“未确认”，而不是把整个 PID 的其它 Space 窗口套用过来。
            guard AXUIElementCopyAttributeValues(application, kAXWindowsAttribute as CFString, 0, 64, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { continue }
            for window in windows {
                guard permitted(deadline) else { break }
                guard remaining.values.contains(where: { $0.pid == candidate.pid }) else { break }
                guard setTimeout(window, deadline: deadline), let number = windowNumber(window),
                      let visible = remaining[number], visible.pid == candidate.pid else { continue }
                guard permitted(deadline), setTimeout(window, deadline: deadline) else { break }
                result.queriedWindowCount += 1
                var rawValues: CFArray?
                let attributes = ["AXFullScreen", kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute] as CFArray
                guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &rawValues) == .success,
                      let values = rawValues as? [Any], values.count == 4,
                      let fullscreen = values[0] as? Bool,
                      let position = point(values[1]), let size = size(values[2]),
                      let minimized = values[3] as? Bool else { continue }
                let frame = CGRect(origin: position, size: size)
                // CGWindow 与 AX 必须指向同一编号和同一呈现矩形，避免过渡或不可见 Space 的陈旧 AX 数据。
                guard DockFullscreenGeometry.approximatelyEqual(frame, visible.frame) else { continue }
                remaining.removeValue(forKey: number)
                if fullscreen && !minimized {
                    result.confirmedDisplayIDs.formUnion(DockFullscreenGeometry.coveredDisplays(
                        windows: [.init(frame: frame, isFullscreen: true)], displays: displays))
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        result.unresolvedDisplayIDs = remaining.values.reduce(into: Set<UInt32>()) { $0.formUnion($1.displayIDs) }
        result.elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        result.budgetExhausted = ProcessInfo.processInfo.systemUptime >= deadline && !remaining.isEmpty
        return result
    }

    private static func permitted(_ deadline: TimeInterval) -> Bool {
        !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline
    }

    private static func setTimeout(_ element: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !Task.isCancelled, remaining > 0 else { return false }
        // 每次 IPC 最多 35 ms，并限制在剩余整轮预算内；不会阻塞主线程。
        return AXUIElementSetMessagingTimeout(element, Float(min(0.035, remaining))) == .success
    }

    private static func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        typealias Getter = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
        // 与现有 AppWindowService 的只读编号桥接一致；取不到精确编号就不把 AX 状态配给可见候选。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var number: CGWindowID = 0
        guard unsafeBitCast(symbol, to: Getter.self)(element, &number) == 0, number != 0 else { return nil }
        return number
    }

    private static func point(_ raw: Any) -> CGPoint? {
        guard CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var point = CGPoint.zero
        return AXValueGetType(value) == .cgPoint && AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func size(_ raw: Any) -> CGSize? {
        guard CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var size = CGSize.zero
        return AXValueGetType(value) == .cgSize && AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}
