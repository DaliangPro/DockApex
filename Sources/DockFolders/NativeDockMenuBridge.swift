import AppKit
import ApplicationServices

enum NativeDockMenuError: LocalizedError, Sendable {
    case permissionDenied
    case dockNotRunning
    case invalidApplicationURL
    case applicationNotInDock
    case menuNotSupported
    case lookupTimedOut
    case requestInProgress
    case requestCancelled
    case requestUnconfirmed(Int32)
    case requestFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "需要辅助功能权限才能显示应用的原生 Dock 菜单。"
        case .dockNotRunning: "系统 Dock 尚未运行，请稍后重试。"
        case .invalidApplicationURL: "这个项目没有有效的应用位置。"
        case .applicationNotInDock: "系统 Dock 中尚未找到这个应用。请先打开应用，再重试原生菜单。"
        case .menuNotSupported: "系统 Dock 没有为这个项目提供显示菜单的辅助功能动作。"
        case .lookupTimedOut: "系统 Dock 响应较慢，暂时无法找到应用菜单，请稍后重试。"
        case .requestInProgress: "正在请求原生 Dock 菜单，请稍候。"
        case .requestCancelled: "本次菜单请求已取消。"
        case .requestUnconfirmed(let code): "系统 Dock 的菜单请求已发出，但尚未确认（AX \(code)）；不自动重试或用弹窗打断可能已打开的菜单。"
        case .requestFailed(let code): "系统 Dock 未确认菜单请求（AX \(code)）。菜单可能已经打开；请先按 Esc 关闭菜单，再重试。"
        }
    }
}

/// AX 对象仅存在于后台 actor 内；只按应用的实际文件位置匹配，不按显示名称猜测。
private actor NativeDockMenuReader {
    private let timeout: Float = 0.2
    private var resolver = NativeDockStatusProcessResolver()

    func showMenu(applicationURL: URL, interaction: ShelfInteractionToken) async -> Result<Void, NativeDockMenuError> {
        guard AXIsProcessTrusted() else { return .failure(.permissionDenied) }
        guard let wantedPath = applicationPath(applicationURL) else { return .failure(.invalidApplicationURL) }
        guard let process = resolver.resolve() else { return .failure(.dockNotRunning) }
        let application = AXUIElementCreateApplication(process.pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var cursor = 0

        while cursor < queue.count, cursor < 256 {
            guard !Task.isCancelled else { return .failure(.requestCancelled) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .failure(.lookupTimedOut) }
            let (element, depth) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, timeout)
            guard let role = attribute(element, kAXRoleAttribute) as? String else { continue }
            if role == "AXDockItem" {
                guard let rawURL = attribute(element, kAXURLAttribute), applicationPath(rawURL) == wantedPath else { continue }
                var actions: CFArray?
                let read = AXUIElementCopyActionNames(element, &actions)
                guard read == .success else { return .failure(.requestFailed(read.rawValue)) }
                guard (actions as? [String])?.contains(kAXShowMenuAction) == true else { return .failure(.menuNotSupported) }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return .failure(.lookupTimedOut) }
                guard await ShelfInteractionCoordinator.shared.permits(interaction), !Task.isCancelled else {
                    return .failure(.requestCancelled)
                }
                guard NativeDockStatusProcess.capture(process.pid) == process else { return .failure(.dockNotRunning) }
                // 此动作只用于用户明确选择的兼容入口，不在后台轮询或常用菜单打开时调用。
                // 不重试：超时不能证明菜单没有打开，再次执行可能改变已经显示的菜单。
                let result = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
                if result == .cannotComplete {
                    // Dock 可以在原生菜单 tracking 期间才回复动作。先只读核对，绝不再次发送 ShowMenu。
                    if let shown = attribute(element, "AXShownMenuUIElement"), CFGetTypeID(shown) == AXUIElementGetTypeID(),
                       attribute(shown as! AXUIElement, kAXRoleAttribute) as? String == kAXMenuRole {
                        return .success(())
                    }
                    return .failure(.requestUnconfirmed(result.rawValue))
                }
                return result == .success ? .success(()) : .failure(.requestFailed(result.rawValue))
            }
            // 不进入其他应用窗口、已展开菜单及其条目。
            guard depth < 4, ["AXApplication", "AXList", "AXGroup", "AXScrollArea"].contains(role) else { continue }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(256 - queue.count).map { ($0, depth + 1) })
            }
        }
        return .failure(.applicationNotInDock)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func applicationPath(_ value: Any) -> String? {
        let url: URL?
        if let direct = value as? URL { url = direct }
        else if let text = value as? String { url = text.hasPrefix("/") ? URL(fileURLWithPath: text) : URL(string: text) }
        else { url = nil }
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 请求由系统 Dock 展示真正的应用菜单。菜单位置、焦点和关闭行为由系统决定。
@MainActor
enum NativeDockMenuBridge {
    private static let reader = NativeDockMenuReader()
    private static var isRequesting = false

    /// completion 的 success 只表示系统接受了 AXShowMenu，不等同于已验证菜单可见或某个菜单项执行成功。
    static func show(for app: AppReference, completion: @escaping @MainActor (Result<Void, NativeDockMenuError>) -> Void) {
        guard !isRequesting else { completion(.failure(.requestInProgress)); return }
        guard AXIsProcessTrusted() else { completion(.failure(.permissionDenied)); return }
        let interaction = ShelfInteractionCoordinator.shared.begin(app)
        isRequesting = true
        let task = Task {
            // 等待当前自有菜单退出 tracking，避免两个菜单争夺同一次事件。
            await withCheckedContinuation { continuation in
                RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
            }
            let result = await reader.showMenu(applicationURL: app.appURL, interaction: interaction)
            isRequesting = false
            guard !Task.isCancelled, ShelfInteractionCoordinator.shared.permits(interaction) else { return }
            completion(result)
        }
        ShelfInteractionCoordinator.shared.track(task, for: interaction)
    }
}
