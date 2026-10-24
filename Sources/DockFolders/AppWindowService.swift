import AppKit
import ApplicationServices
import Darwin

private enum AppWindowProcessIdentity {
    static func token(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }
}

/// 跨进程 AX 对象始终留在读取 actor 内；界面只持有可发送的窗口快照。
struct AppWindowInfo: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isMinimized: Bool
    let isMain: Bool
    let isFocused: Bool
    let cgWindowID: CGWindowID?
    /// WindowServer / AX 坐标：主显示器左上为原点，y 向下。
    let quartzFrame: CGRect?

    init(id: String, title: String, isMinimized: Bool, isMain: Bool, isFocused: Bool,
         cgWindowID: CGWindowID? = nil, quartzFrame: CGRect? = nil) {
        self.id = id; self.title = title; self.isMinimized = isMinimized
        self.isMain = isMain; self.isFocused = isFocused; self.cgWindowID = cgWindowID; self.quartzFrame = quartzFrame
    }
}

struct AppWindowMinimizationEvent: Sendable {
    let application: AppReference
    let windowID: String
    let isMinimized: Bool
    let previousWindow: AppWindowInfo?
    let occurredAt: Date
    let cgWindowID: CGWindowID?
    let notificationWindowID: String
}

private enum AppWindowNumber {
    static func read(_ element: AXUIElement) -> CGWindowID? {
        typealias Getter = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var number: CGWindowID = 0
        guard unsafeBitCast(symbol, to: Getter.self)(element, &number) == 0, number != 0 else { return nil }
        return number
    }
}

struct AppWindowSnapshot: Sendable {
    let processIdentifier: pid_t
    let windows: [AppWindowInfo]
    let hasAccessibilityPermission: Bool
    let errorDescription: String?
    let updatedAt: Date
    /// 只有完整读取才有资格删除旧窗口；超时和部分读取保留已知入口。
    let isComplete: Bool

    init(processIdentifier: pid_t, windows: [AppWindowInfo], hasAccessibilityPermission: Bool,
         errorDescription: String?, updatedAt: Date, isComplete: Bool = true) {
        self.processIdentifier = processIdentifier; self.windows = windows
        self.hasAccessibilityPermission = hasAccessibilityPermission; self.errorDescription = errorDescription
        self.updatedAt = updatedAt; self.isComplete = isComplete
    }

    func retainingUnreadWindows(from previous: AppWindowSnapshot?) -> AppWindowSnapshot {
        guard !isComplete, let previous, previous.processIdentifier == processIdentifier else { return self }
        let updates = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIDs = Set(previous.windows.map(\.id))
        let retained = previous.windows.map { updates[$0.id] ?? $0 } + windows.filter { !oldIDs.contains($0.id) }
        return AppWindowSnapshot(processIdentifier: processIdentifier, windows: retained,
            hasAccessibilityPermission: hasAccessibilityPermission, errorDescription: errorDescription,
            updatedAt: updatedAt, isComplete: false)
    }
}

struct AppWindowActionResult: Sendable {
    let succeeded: Bool
    let errorDescription: String?
}

struct AppWindowCacheEntry: Sendable {
    let application: AppReference
    let snapshot: AppWindowSnapshot
    let processIdentity: String
}

private let appWindowObserverCallback: AXObserverCallback = { _, element, notification, context in
    guard let context else { return }
    let pid = pid_t(Int(bitPattern: context))
    // context 只编码 PID，不解引用对象；注销后迟到的通知也不会访问已释放对象。
    let name = notification as String
    let windowID = "\(pid):\(CFHash(element))"
    let number = name == kAXWindowMiniaturizedNotification || name == kAXWindowDeminiaturizedNotification ? AppWindowNumber.read(element) : nil
    Task { @MainActor in AppWindowService.shared.receiveAccessibilityChange(processIdentifier: pid, notification: name, windowID: windowID, cgWindowID: number) }
}

actor AppWindowReader {
    private var elements: [pid_t: [String: AXUIElement]] = [:]
    private var elementIdentities: [pid_t: String] = [:]
    private let timeout: Float = 0.2
    private struct Observation {
        let observer: AXObserver
        let application: AXUIElement
        let processIdentity: String
        var windows: [String: AXUIElement] = [:]
        var successfulRegistrations = 0
    }
    private var observations: [pid_t: Observation] = [:]

    func scan(processIdentifier pid: pid_t, applicationName: String) -> AppWindowSnapshot {
        guard AXIsProcessTrusted() else {
            retainProcesses([])
            return snapshot(pid, error: "需要辅助功能权限才能读取与恢复窗口。", trusted: false, complete: false)
        }
        guard let processIdentity = AppWindowProcessIdentity.token(pid) else {
            return snapshot(pid, error: "应用已退出或无法确认进程身份。", complete: false)
        }
        if elementIdentities[pid] != processIdentity {
            elements[pid] = nil
            elementIdentities[pid] = processIdentity
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windowElements = value as? [AXUIElement] else {
            return snapshot(pid, error: status == .success || status == .noValue ? "暂时无法读取完整窗口列表。" : describe(status), complete: false)
        }
        var focusedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue)
        let focusedWindow = focusedValue.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let attributes = [kAXTitleAttribute, kAXMinimizedAttribute, kAXMainAttribute, kAXRoleAttribute, kAXSizeAttribute, kAXSubroleAttribute, kAXPositionAttribute] as CFArray
        let deadline = Date().addingTimeInterval(0.8)
        var handles: [String: AXUIElement] = [:]
        var windows: [AppWindowInfo] = []
        var incomplete = windowElements.count > 64
        for element in windowElements.prefix(64) {
            if Date() > deadline { incomplete = true; break }
            AXUIElementSetMessagingTimeout(element, timeout)
            var values: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values)
            guard result == .success, let fields = values as? [Any], fields.count == 7 else { incomplete = true; continue }
            guard let role = fields[3] as? String else { incomplete = true; continue }
            guard role == kAXWindowRole else { continue }
            guard fields[1] as? Bool != nil else { incomplete = true; continue }
            var id = "\(pid):\(CFHash(element))"
            while handles[id] != nil { id += ":" }
            handles[id] = element
            let sizeValue = fields[4] as AnyObject
            if CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                let axSize = sizeValue as! AXValue
                var size = CGSize.zero
                if AXValueGetType(axSize) == .cgSize, AXValueGetValue(axSize, .cgSize, &size),
                   (size.width <= 1 || size.height <= 1), (fields[1] as? Bool) != true { continue }
            }
            let isMinimized = fields[1] as? Bool ?? false
            let isMain = fields[2] as? Bool ?? false
            let isFocused = focusedWindow.map { CFEqual($0, element) } ?? false
            // 系统可能把悬浮提示作为 AXDialog 暴露；它不是 Dock 的独立文档窗口。
            // 仍保留其 AX 句柄与通知，成为主窗口或获得焦点后会重新进入列表。
            if let subrole = fields[5] as? String,
               [kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole].contains(subrole),
               !isMinimized, !isMain, !isFocused { continue }
            let rawTitle = fields[0] as? String ?? ""
            var frame: CGRect?
            let positionObject = fields[6] as AnyObject
            if CFGetTypeID(positionObject) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                var point = CGPoint.zero; var size = CGSize.zero
                if AXValueGetValue(positionObject as! AXValue, .cgPoint, &point), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                    frame = CGRect(origin: point, size: size)
                }
            }
            windows.append(AppWindowInfo(
                id: id,
                title: rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(applicationName) 窗口" : rawTitle,
                isMinimized: isMinimized,
                isMain: isMain,
                isFocused: isFocused,
                cgWindowID: AppWindowNumber.read(element),
                quartzFrame: frame
            ))
        }
        if incomplete {
            // AX 超时不能移除尚未读到的最小化窗口句柄或通知。
            handles.merge(elements[pid] ?? [:]) { current, _ in current }
        }
        elements[pid] = handles
        elementIdentities[pid] = processIdentity
        synchronizeObservation(processIdentifier: pid, processIdentity: processIdentity, application: application, windows: handles)
        return snapshot(pid, windows: windows, error: incomplete ? "应用响应较慢，暂时保留尚未读取的窗口。" : nil, complete: !incomplete)
    }

    func retainProcesses(_ processes: Set<pid_t>) {
        for pid in Array(observations.keys) where !processes.contains(pid) {
            if let observation = observations.removeValue(forKey: pid) {
                // CFRunLoop 的增删接口可从其他线程调用；观察器回调只在主 RunLoop 递送。
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
            }
            elements[pid] = nil
            elementIdentities[pid] = nil
        }
        elements = elements.filter { processes.contains($0.key) }
        elementIdentities = elementIdentities.filter { processes.contains($0.key) }
    }

    func observationRegistrationCount(processIdentifier pid: pid_t) -> Int {
        observations[pid]?.successfulRegistrations ?? 0
    }

    private func synchronizeObservation(processIdentifier pid: pid_t, processIdentity: String, application: AXUIElement, windows: [String: AXUIElement]) {
        let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
        let windowNotifications = [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXResizedNotification, kAXMovedNotification]
        let context = UnsafeMutableRawPointer(bitPattern: Int(pid))
        if let old = observations[pid], old.processIdentity != processIdentity {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old.observer), .commonModes)
            observations[pid] = nil
        }
        if observations[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, appWindowObserverCallback, &observer) == .success, let observer else { return }
            var observation = Observation(observer: observer, application: application, processIdentity: processIdentity)
            for notification in appNotifications {
                if AXObserverAddNotification(observer, application, notification as CFString, context) == .success { observation.successfulRegistrations += 1 }
            }
            observations[pid] = observation
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard var observation = observations[pid] else { return }
        let deadline = Date().addingTimeInterval(0.5)
        for (id, oldWindow) in observation.windows where windows[id] == nil {
            for notification in windowNotifications {
                AXObserverRemoveNotification(observation.observer, oldWindow, notification as CFString)
            }
            observation.windows[id] = nil
        }
        for (id, window) in windows where observation.windows[id] == nil {
            guard Date() < deadline else { break }
            for notification in windowNotifications {
                if AXObserverAddNotification(observation.observer, window, notification as CFString, context) == .success { observation.successfulRegistrations += 1 }
            }
            observation.windows[id] = window
        }
        observations[pid] = observation
    }

    func raise(windowID: String, processIdentifier pid: pid_t) async -> AppWindowActionResult {
        guard !Task.isCancelled, let token = AppWindowProcessIdentity.token(pid), token == elementIdentities[pid],
              let window = elements[pid]?[windowID] else {
            return AppWindowActionResult(succeeded: false, errorDescription: "窗口已关闭，请重新打开菜单。")
        }
        AXUIElementSetMessagingTimeout(window, timeout)
        var minimized: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if read == .success, (minimized as? Bool) == true {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else { return AppWindowActionResult(succeeded: false, errorDescription: describe(result)) }
        }
        var result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Genie 动画期间，窗口可能已解除最小化但暂时不接受 Raise；短暂重试仍不占主线程。
        for _ in 0..<3 where result == .cannotComplete {
            do { try await Task.sleep(for: .milliseconds(120)) } catch {
                return AppWindowActionResult(succeeded: false, errorDescription: nil)
            }
            guard !Task.isCancelled, AppWindowProcessIdentity.token(pid) == token else {
                return AppWindowActionResult(succeeded: false, errorDescription: nil)
            }
            result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        // 部分应用只接受 AXMain；两者均不支持时保留错误，不把进程激活冒充窗口抬升。
        if result != .success {
            let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return AppWindowActionResult(succeeded: mainResult == .success, errorDescription: mainResult == .success ? nil : describe(result))
        }
        return AppWindowActionResult(succeeded: true, errorDescription: nil)
    }

    /// 按窗口自己的关闭按钮，与点红色按钮相同：有未存内容时由应用自己弹出存储提示，窗口留着。
    func close(windowID: String, processIdentifier pid: pid_t) -> AppWindowActionResult {
        guard !Task.isCancelled, let token = AppWindowProcessIdentity.token(pid), token == elementIdentities[pid],
              let window = elements[pid]?[windowID] else {
            return AppWindowActionResult(succeeded: false, errorDescription: "窗口已关闭。")
        }
        AXUIElementSetMessagingTimeout(window, timeout)
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return AppWindowActionResult(succeeded: false, errorDescription: "这个窗口没有关闭按钮。")
        }
        let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        return AppWindowActionResult(succeeded: result == .success, errorDescription: result == .success ? nil : describe(result))
    }

    func restoreIfAllMinimized(processIdentifier pid: pid_t, applicationName: String) async -> AppWindowActionResult {
        let current = scan(processIdentifier: pid, applicationName: applicationName)
        guard current.isComplete, !current.windows.isEmpty, current.windows.allSatisfy(\.isMinimized) else {
            return AppWindowActionResult(succeeded: false, errorDescription: nil)
        }
        let target = current.windows.first(where: \.isFocused) ?? current.windows.first(where: \.isMain) ?? current.windows[0]
        return await raise(windowID: target.id, processIdentifier: pid)
    }

    private func snapshot(_ pid: pid_t, windows: [AppWindowInfo] = [], error: String? = nil, trusted: Bool = true, complete: Bool = true) -> AppWindowSnapshot {
        AppWindowSnapshot(processIdentifier: pid, windows: windows, hasAccessibilityPermission: trusted, errorDescription: error, updatedAt: Date(), isComplete: complete)
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .cannotComplete: "应用暂时没有响应，请稍后重试。"
        case .apiDisabled: "辅助功能访问已关闭。"
        case .attributeUnsupported, .actionUnsupported: "此应用不支持这项窗口操作。"
        case .invalidUIElement: "窗口已关闭，请重新打开菜单。"
        default: "窗口操作失败（AX \(error.rawValue)）。"
        }
    }
}

@MainActor
final class AppWindowService {
    static let shared = AppWindowService()
    private let reader = AppWindowReader()
    private struct Identity: Hashable { let path: String; let pid: pid_t; let token: String }
    private var cache: [String: AppWindowCacheEntry] = [:]
    private var pending: [Identity: Task<Void, Never>] = [:]
    private var requestIDs: [Identity: UUID] = [:]
    private var completions: [Identity: [(AppWindowSnapshot) -> Void]] = [:]
    private var tracked: [pid_t: AppReference] = [:]
    private var trackedTokens: [pid_t: String] = [:]
    private var observerRefreshes: [pid_t: Task<Void, Never>] = [:]
    private var dirty = Set<Identity>()
    /// 窗口有变化；参数为应用栏要显示的最小化窗口（编号与标题）是否变了。移动、改尺寸、改标题、换焦点只需
    /// 窗口避让重新看一轮，不必刷新整条应用栏。
    var onChange: ((_ minimizedChanged: Bool) -> Void)?

    static func minimizedKeys(_ windows: [AppWindowInfo]) -> [String] {
        windows.filter(\.isMinimized).map { $0.id + "\t" + $0.title }
    }
    /// 最小化通知不等 60ms 列表去抖，避免窗口消失后再开始过渡。
    var onMinimizationEvent: ((AppWindowMinimizationEvent) -> Void)?
    /// 返回 true 表示先播放截图恢复动画，再调用 completion 执行真实 AX 恢复。
    var animateRestore: ((AppReference, AppWindowInfo, @escaping () -> Void) -> Bool)?
    private(set) var accessibilityEventCount = 0
    private(set) var accessibilityEventsByNotification: [String: Int] = [:]

    var cachedSnapshots: [AppWindowCacheEntry] {
        cache.values.filter { ShelfAppActions.running($0.application)?.processIdentifier == $0.snapshot.processIdentifier && AppWindowProcessIdentity.token($0.snapshot.processIdentifier) == $0.processIdentity }
            .sorted { $0.application.path < $1.application.path }
    }

    func cachedWindows(for app: AppReference) -> AppWindowSnapshot? {
        guard let current = ShelfAppActions.running(app), let entry = cache[app.path],
              entry.snapshot.processIdentifier == current.processIdentifier,
              AppWindowProcessIdentity.token(current.processIdentifier) == entry.processIdentity else { return nil }
        return entry.snapshot
    }

    /// 调用方在工作区事件及低频兜底时提供当前运行应用；默认避免重复遍历新鲜缓存。
    func refreshRunningApplications(_ apps: [AppReference], force: Bool = false) {
        var next: [pid_t: AppReference] = [:]
        var tokens: [pid_t: String] = [:]
        for app in apps {
            if let running = ShelfAppActions.running(app), let token = AppWindowProcessIdentity.token(running.processIdentifier) {
                next[running.processIdentifier] = app; tokens[running.processIdentifier] = token
            }
        }
        let identities = Set(next.map { Identity(path: $0.value.path, pid: $0.key, token: tokens[$0.key]!) })
        let oldTrackedPIDs = Set(tracked.keys)
        tracked = next
        trackedTokens = tokens
        let oldEntries = cache.values.filter { !identities.contains(Identity(path: $0.application.path, pid: $0.snapshot.processIdentifier, token: $0.processIdentity)) }
        cache = cache.filter { identities.contains(Identity(path: $0.value.application.path, pid: $0.value.snapshot.processIdentifier, token: $0.value.processIdentity)) }
        for key in Array(pending.keys) where !identities.contains(key) {
            cancelRequest(key, message: "应用已退出或已重新启动，请重新打开菜单。")
        }
        for pid in Array(observerRefreshes.keys) where next[pid] == nil { observerRefreshes.removeValue(forKey: pid)?.cancel() }
        let pids = Set(next.keys)
        if oldTrackedPIDs != pids { Task { [reader] in await reader.retainProcesses(pids) } }
        if oldEntries.contains(where: { !$0.snapshot.windows.isEmpty }) {
            onChange?(oldEntries.contains { $0.snapshot.windows.contains(where: \.isMinimized) })
        }
        for app in next.values {
            if force || cachedWindows(for: app).map({ Date().timeIntervalSince($0.updatedAt) >= 8 }) ?? true { refresh(app) }
        }
    }

    func stopObserving() {
        for task in pending.values { task.cancel() }
        for task in observerRefreshes.values { task.cancel() }
        let callbacks = completions
        pending.removeAll(); requestIDs.removeAll(); completions.removeAll(); observerRefreshes.removeAll(); dirty.removeAll(); tracked.removeAll(); trackedTokens.removeAll()
        let hadWindows = cache.values.contains { !$0.snapshot.windows.isEmpty }
        cache.removeAll()
        Task { [reader] in await reader.retainProcesses([]) }
        for (identity, handlers) in callbacks {
            let cancelled = unavailableSnapshot(identity.pid, message: "窗口读取已停止。")
            for handler in handlers { handler(cancelled) }
        }
        if hadWindows { onChange?(true) }
    }

    fileprivate func receiveAccessibilityChange(processIdentifier pid: pid_t, notification: String, windowID rawWindowID: String, cgWindowID: CGWindowID?) {
        accessibilityEventCount += 1
        accessibilityEventsByNotification[notification, default: 0] += 1
        guard let app = tracked[pid], ShelfAppActions.running(app)?.processIdentifier == pid,
              let token = trackedTokens[pid], AppWindowProcessIdentity.token(pid) == token else { return }
        if notification == kAXWindowMiniaturizedNotification || notification == kAXWindowDeminiaturizedNotification {
            let minimized = notification == kAXWindowMiniaturizedNotification
            let previousWindow = cache[app.path]?.snapshot.windows.first(where: { $0.id == rawWindowID })
                ?? cache[app.path]?.snapshot.windows.first(where: { cgWindowID != nil && $0.cgWindowID == cgWindowID })
            let windowID = previousWindow?.id ?? rawWindowID
            if let entry = cache[app.path], let previousWindow, previousWindow.isMinimized != minimized {
                let nextWindows = entry.snapshot.windows.map { window in
                    window.id == windowID ? AppWindowInfo(id: window.id, title: window.title, isMinimized: minimized,
                        isMain: window.isMain, isFocused: window.isFocused, cgWindowID: window.cgWindowID, quartzFrame: window.quartzFrame) : window
                }
                cache[app.path] = AppWindowCacheEntry(application: entry.application,
                    snapshot: AppWindowSnapshot(processIdentifier: pid, windows: nextWindows,
                        hasAccessibilityPermission: entry.snapshot.hasAccessibilityPermission,
                        errorDescription: entry.snapshot.errorDescription, updatedAt: Date(), isComplete: entry.snapshot.isComplete), processIdentity: entry.processIdentity)
                // 先让栏内出现真实最小化窗口入口，后取动画终点；完整 AX 复查仍由下方去抖执行。
                onChange?(true)
            }
            onMinimizationEvent?(AppWindowMinimizationEvent(application: app, windowID: windowID,
                isMinimized: minimized, previousWindow: previousWindow, occurredAt: Date(),
                cgWindowID: cgWindowID ?? previousWindow?.cgWindowID, notificationWindowID: rawWindowID))
        }
        if notification == kAXUIElementDestroyedNotification, let entry = cache[app.path] {
            let windows = entry.snapshot.windows.filter { $0.id != rawWindowID && (cgWindowID == nil || $0.cgWindowID != cgWindowID) }
            if windows != entry.snapshot.windows {
                cache[app.path] = AppWindowCacheEntry(application: app,
                    snapshot: AppWindowSnapshot(processIdentifier: pid, windows: windows,
                        hasAccessibilityPermission: entry.snapshot.hasAccessibilityPermission,
                        errorDescription: entry.snapshot.errorDescription, updatedAt: Date(), isComplete: entry.snapshot.isComplete), processIdentity: token)
                onChange?(Self.minimizedKeys(windows) != Self.minimizedKeys(entry.snapshot.windows))
            }
        }
        guard observerRefreshes[pid] == nil else { return }
        observerRefreshes[pid] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self else { return }
            observerRefreshes[pid] = nil
            guard tracked[pid]?.path == app.path, trackedTokens[pid] == token else { return }
            let identity = Identity(path: app.path, pid: pid, token: token)
            if pending[identity] != nil { dirty.insert(identity) }
            else { refresh(app) }
        }
    }

    func refresh(_ app: AppReference, completion: ((AppWindowSnapshot) -> Void)? = nil) {
        guard let running = ShelfAppActions.running(app) else {
            completion?(AppWindowSnapshot(processIdentifier: 0, windows: [], hasAccessibilityPermission: AXIsProcessTrusted(), errorDescription: nil, updatedAt: Date()))
            return
        }
        let pid = running.processIdentifier
        guard let token = AppWindowProcessIdentity.token(pid) else {
            completion?(unavailableSnapshot(pid, message: "应用已退出或无法确认进程身份。"))
            return
        }
        let identity = Identity(path: app.path, pid: pid, token: token)
        tracked[pid] = app
        trackedTokens[pid] = token
        if let completion { completions[identity, default: []].append(completion) }
        guard pending[identity] == nil else { return }
        let requestID = UUID()
        requestIDs[identity] = requestID
        pending[identity] = Task { [weak self, reader] in
            guard !Task.isCancelled else { return }
            let scanned = await reader.scan(processIdentifier: pid, applicationName: app.name)
            guard let self, requestIDs[identity] == requestID else { return }
            guard !Task.isCancelled, tracked[pid]?.path == app.path,
                  ShelfAppActions.running(app)?.processIdentifier == pid,
                  AppWindowProcessIdentity.token(pid) == token else {
                cancelRequest(identity, message: "应用已退出或已重新启动，请重新打开菜单。")
                return
            }
            let previousEntry = cache[app.path]
            let previous = previousEntry?.processIdentity == token ? previousEntry?.snapshot : nil
            let old = previousEntry?.snapshot.windows ?? []
            let result = scanned.retainingUnreadWindows(from: previous)
            cache[app.path] = AppWindowCacheEntry(application: app, snapshot: result, processIdentity: token)
            pending[identity] = nil
            requestIDs[identity] = nil
            let callbacks = completions.removeValue(forKey: identity) ?? []
            for callback in callbacks { callback(result) }
            if old != result.windows { onChange?(Self.minimizedKeys(old) != Self.minimizedKeys(result.windows)) }
            if dirty.remove(identity) != nil { refresh(app) }
        }
    }

    private func unavailableSnapshot(_ pid: pid_t, message: String) -> AppWindowSnapshot {
        AppWindowSnapshot(processIdentifier: pid, windows: [], hasAccessibilityPermission: AXIsProcessTrusted(),
                          errorDescription: message, updatedAt: Date(), isComplete: false)
    }

    private func cancelRequest(_ identity: Identity, message: String) {
        pending.removeValue(forKey: identity)?.cancel()
        requestIDs[identity] = nil
        dirty.remove(identity)
        let callbacks = completions.removeValue(forKey: identity) ?? []
        let result = unavailableSnapshot(identity.pid, message: message)
        for callback in callbacks { callback(result) }
    }

    func select(_ window: AppWindowInfo, in app: AppReference, interaction existing: ShelfInteractionToken? = nil) {
        let interaction = existing ?? ShelfInteractionCoordinator.shared.begin(app)
        guard ShelfInteractionCoordinator.shared.permits(interaction),
              let running = ShelfAppActions.running(app), let token = AppWindowProcessIdentity.token(running.processIdentifier),
              let currentWindow = cachedWindows(for: app)?.windows.first(where: { $0.id == window.id }) else {
            refresh(app)
            return
        }
        let window = currentWindow
        let pid = running.processIdentifier
        running.unhide()
        let performRestore = { [self, reader] in
            guard ShelfInteractionCoordinator.shared.permits(interaction),
                  AppWindowProcessIdentity.token(pid) == token else { return }
            let task = Task { @MainActor in
                guard !Task.isCancelled, ShelfInteractionCoordinator.shared.permits(interaction) else { return }
                let result = await reader.raise(windowID: window.id, processIdentifier: pid)
                guard !Task.isCancelled, ShelfInteractionCoordinator.shared.permits(interaction),
                      AppWindowProcessIdentity.token(pid) == token else { return }
                if result.succeeded {
                    if let current = ShelfAppActions.running(app), current.processIdentifier == pid { NSApp.yieldActivation(to: current); current.activate() }
                    refresh(app)
                } else if let message = result.errorDescription {
                    ShelfAppActions.showError(title: "无法显示“\(window.title)”", message: message)
                }
            }
            ShelfInteractionCoordinator.shared.track(task, for: interaction)
        }
        if window.isMinimized, animateRestore?(app, window, performRestore) == true { return }
        performRestore()
    }

    /// 关闭窗口（窗口预览里的关闭按钮）：不激活应用，结果回到主线程。
    func close(_ window: AppWindowInfo, in app: AppReference, completion: @escaping @MainActor (AppWindowActionResult) -> Void) {
        guard let running = ShelfAppActions.running(app) else {
            completion(AppWindowActionResult(succeeded: false, errorDescription: "应用已退出。"))
            return
        }
        let pid = running.processIdentifier
        Task { @MainActor [reader] in
            completion(await reader.close(windowID: window.id, processIdentifier: pid))
        }
    }

    func restoreIfAllMinimized(_ app: AppReference, interaction existing: ShelfInteractionToken? = nil) {
        let interaction = existing ?? ShelfInteractionCoordinator.shared.begin(app)
        guard ShelfAppActions.running(app) != nil, ShelfInteractionCoordinator.shared.permits(interaction) else { return }
        let restore: (AppWindowSnapshot) -> Void = { [weak self] snapshot in
            guard let self, ShelfInteractionCoordinator.shared.permits(interaction),
                  snapshot.isComplete, !snapshot.windows.isEmpty, snapshot.windows.allSatisfy(\.isMinimized),
                  let target = snapshot.windows.first(where: \.isFocused) ?? snapshot.windows.first(where: \.isMain) ?? snapshot.windows.first else { return }
            select(target, in: app, interaction: interaction)
        }
        if let snapshot = cachedWindows(for: app), Date().timeIntervalSince(snapshot.updatedAt) < 0.5, snapshot.isComplete {
            restore(snapshot)
        } else {
            // 无缓存和旧缓存都先统一刷新，再走 select；截图恢复与焦点保护不再漏掉分支。
            refresh(app, completion: restore)
        }
    }

}

@MainActor
final class ShelfWindowMenu: NSMenu, NSMenuDelegate {
    private let application: AppReference

    init(application: AppReference) {
        self.application = application
        super.init(title: "窗口")
        delegate = self
        populate(AppWindowService.shared.cachedWindows(for: application))
    }

    required init(coder: NSCoder) { fatalError("不支持从归档载入菜单") }

    func menuWillOpen(_ menu: NSMenu) {
        AppWindowService.shared.refresh(application) { [weak self] snapshot in self?.populate(snapshot) }
    }

    private func populate(_ snapshot: AppWindowSnapshot?) {
        removeAllItems()
        guard let snapshot else { addStatus("正在读取窗口…"); return }
        for window in snapshot.windows {
            let item = ShelfMenuItem(window.title) { [application] in AppWindowService.shared.select(window, in: application) }
            if window.isMinimized {
                item.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: "已最小化")
                item.image?.size = NSSize(width: 10, height: 10)
            } else if window.isFocused || window.isMain { item.state = .on }
            addItem(item)
        }
        if let error = snapshot.errorDescription {
            if !items.isEmpty { addItem(.separator()) }
            addStatus(error)
        } else if snapshot.windows.isEmpty { addStatus("没有打开的窗口") }
    }

    private func addStatus(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

/// 顶层右键菜单直接展示窗口；保留菜单实例后再异步更新，不切换到系统 Dock。
@MainActor
final class ShelfApplicationMenu: NSMenu, NSMenuDelegate {
    private let application: AppReference
    private var installedWindows: [NSMenuItem] = []
    private let onWindowSelected: (() -> Void)?
    /// 窗口列表在打开后补全时通知（弹出框菜单据此重排）。
    var onItemsChanged: (() -> Void)?

    init(application: AppReference, onWindowSelected: (() -> Void)? = nil) {
        self.application = application
        self.onWindowSelected = onWindowSelected
        super.init(title: application.name)
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("不支持从归档载入菜单") }

    func installCachedWindows() { install(AppWindowService.shared.cachedWindows(for: application)) }

    func menuWillOpen(_ menu: NSMenu) {
        guard ShelfAppActions.running(application) != nil else { return }
        AppWindowService.shared.refresh(application) { [weak self] snapshot in self?.install(snapshot) }
    }

    private func install(_ snapshot: AppWindowSnapshot?) {
        defer { onItemsChanged?() }
        for item in installedWindows where item.menu === self { removeItem(item) }
        installedWindows = []
        guard let snapshot else { return }
        for window in snapshot.windows {
            let item = ShelfMenuItem(window.title) { [application, onWindowSelected] in
                AppWindowService.shared.select(window, in: application)
                onWindowSelected?()
            }
            if window.isMinimized {
                item.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: "已最小化")
                item.image?.size = NSSize(width: 10, height: 10)
            } else if window.isFocused || window.isMain { item.state = .on }
            installedWindows.append(item)
        }
        if let error = snapshot.errorDescription, snapshot.windows.isEmpty {
            let status = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            status.isEnabled = false
            installedWindows.append(status)
        }
        guard !installedWindows.isEmpty else { return }
        installedWindows.insert(.separator(), at: 0)
        for (offset, item) in installedWindows.enumerated() { insertItem(item, at: min(1 + offset, numberOfItems)) }
    }
}
