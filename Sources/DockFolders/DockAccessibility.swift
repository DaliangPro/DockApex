import AppKit
import ApplicationServices

/// 坐标采用 CoreGraphics / AX 的屏幕坐标：主显示器左上角为原点。
struct DockAppItem: Sendable, Hashable {
    let appURL: URL
    let frame: CGRect
    let label: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.appURL == rhs.appURL && lhs.frame == rhs.frame && lhs.label == rhs.label
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(appURL)
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.size.width)
        hasher.combine(frame.size.height)
        hasher.combine(label)
    }
}

struct DockAccessibilitySnapshot: Sendable {
    let processID: pid_t
    let items: [DockAppItem]
    let visitedElementCount: Int
    /// 超时或数量上限触发时不把部分结果当成完整 Dock。
    var isComplete: Bool = true
}

enum DockAccessibilityError: LocalizedError {
    case notTrusted
    case dockNotRunning
    case noApplicationItems(Int)
    case failed(AXError)

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "尚未获得辅助功能权限。"
        case .dockNotRunning: return "未找到系统 Dock 进程。"
        case .noApplicationItems(let count): return "已读取 \(count) 个 Dock 元素，但没有识别到应用图标。请先显示系统 Dock。"
        case .failed(let error): return "读取系统 Dock 失败（辅助功能错误 \(error.rawValue)）。"
        }
    }
}

/// 只读公开辅助功能接口；不写 Dock、不执行辅助功能动作。
enum DockAccessibility {
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @MainActor
    static var dockProcessID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    @MainActor
    static func currentSnapshot() throws -> DockAccessibilitySnapshot {
        guard hasAccessibilityPermission else { throw DockAccessibilityError.notTrusted }
        guard let pid = dockProcessID else { throw DockAccessibilityError.dockNotRunning }
        return try snapshot(processID: pid)
    }

    /// 可从工作线程调用；每次建立独立 AX 对象，避免跨线程共享 AX 实例。
    static func snapshot(processID: pid_t) throws -> DockAccessibilitySnapshot {
        guard hasAccessibilityPermission else { throw DockAccessibilityError.notTrusted }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.06)
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var cursor = 0
        var items: [DockAppItem] = []
        var seen = Set<URL>()
        var firstError: AXError?

        let deadline = ProcessInfo.processInfo.systemUptime + 0.24
        // Dock 的常见层级为 AXApplication → AXList → AXDockItem；限深和限数避免异常树。
        while cursor < queue.count && cursor < 400 && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.025)
            if let item = appItem(element) {
                if seen.insert(item.appURL).inserted { items.append(item) }
                // 应用图标下的菜单不是额外的 Dock 固定项，不继续展开菜单子树。
                continue
            }
            guard depth < 4 else { continue }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if error == .success, let children = value as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            } else if error != .attributeUnsupported && firstError == nil {
                firstError = error
            }
        }
        guard !items.isEmpty else {
            if cursor == 1, let firstError { throw DockAccessibilityError.failed(firstError) }
            throw DockAccessibilityError.noApplicationItems(cursor)
        }
        return DockAccessibilitySnapshot(processID: processID, items: items, visitedElementCount: cursor,
                                         isComplete: cursor >= queue.count)
    }

    /// 后台确认按下点属于真实 Dock，避免覆盖窗口误触发合并；鼠标事件始终原样通过。
    static func isDock(at point: CGPoint, processID: pid_t) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.04)
        var value: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &value) == .success,
              let element = value else { return false }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == processID
    }

    /// 按点补读只返回真实 Dock 图标；不读取其它应用窗口内容，也不执行 AX 动作。
    static func applicationItem(at point: CGPoint, processID: pid_t) -> DockAppItem? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.04)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        for _ in 0..<5 {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == processID,
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.025)
            if let item = appItem(element) { return item }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// 已知入口 URL 的补读只在命中身份后才请求几何，避免前半栏慢元素饿死后半栏。
    static func applicationItem(url: URL, processID: pid_t) -> DockAppItem? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.025)
        let expected = url.standardizedFileURL
        let deadline = ProcessInfo.processInfo.systemUptime + 0.24
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var cursor = 0
        while cursor < queue.count && cursor < 400 && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.025)
            if let raw = attribute(element, kAXURLAttribute), let candidate = applicationURL(raw) {
                if candidate.standardizedFileURL == expected { return appItem(element) }
                if depth > 0 { continue }
            }
            guard depth < 4, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    @MainActor
    static func diagnose() -> String {
        let listen = CGPreflightListenEventAccess() ? "已允许" : "未允许或未请求"
        let post = CGPreflightPostEventAccess() ? "已允许" : "未允许或未请求"
        guard hasAccessibilityPermission else {
            return "辅助功能：未授权；输入监听：\(listen)；事件发送：\(post)。尚未读取 Dock，所有输入由系统处理。"
        }
        do {
            let snapshot = try currentSnapshot()
            let names = snapshot.items.map { "\($0.label) [\(Int($0.frame.width))×\(Int($0.frame.height))]" }.joined(separator: "、")
            return "辅助功能：已授权；输入监听：\(listen)；事件发送：\(post)；Dock PID：\(snapshot.processID)；读取元素：\(snapshot.visitedElementCount)；识别应用：\(snapshot.items.count)。\n\(names)"
        } catch {
            return "辅助功能：已授权；输入监听：\(listen)；事件发送：\(post)；\(error.localizedDescription) 普通输入仍由系统处理。"
        }
    }

    private static func appItem(_ element: AXUIElement) -> DockAppItem? {
        // URL 是身份依据；不用同名应用或当前前台应用猜测目标。
        guard let rawURL = attribute(element, kAXURLAttribute), let url = applicationURL(rawURL),
              let position = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute),
              size.width > 5, size.height > 5, size.width < 512, size.height < 512 else { return nil }
        let name = (attribute(element, kAXTitleAttribute) as? String)
            ?? (attribute(element, kAXDescriptionAttribute) as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return DockAppItem(appURL: url.standardizedFileURL, frame: CGRect(origin: position, size: size), label: name)
    }

    private static func applicationURL(_ value: CFTypeRef) -> URL? {
        let url: URL?
        if let direct = value as? URL {
            url = direct
        } else if let string = value as? String {
            url = string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
        } else {
            url = nil
        }
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }
        return url
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}
