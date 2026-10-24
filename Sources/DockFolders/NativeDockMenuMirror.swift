import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

/// App 自带的 Dock 菜单只经系统 Dock 的私有端口提供；影子 Dock 中运行的 App 有对应格子。
/// 这里在遮盖下打开其原生菜单读取条目（或按标题路径执行），立即取消，避免系统菜单在屏幕上闪现。
/// 遮盖是实时捕捉（排除系统 Dock 与它的菜单），只在内存中短暂显示，不保存。
struct NativeDockMenuEntry: Sendable, Equatable {
    var title: String
    var enabled: Bool
    var isSeparator: Bool
    var checked: Bool
    var children: [NativeDockMenuEntry]
}

/// 合并到自制栏菜单的部分：App 自定义项、“选项”中的系统项、显示所有窗口。
struct NativeDockMenuMirrorContent: Sendable, Equatable {
    var custom: [NativeDockMenuEntry]
    var options: NativeDockMenuEntry?
    var showAllWindows: NativeDockMenuEntry?
}

@MainActor
final class NativeDockMenuMirror {
    static let shared = NativeDockMenuMirror()
    private var cache: [pid_t: (time: TimeInterval, content: NativeDockMenuMirrorContent)] = [:]
    private var busy = false
    private let cover = ShadowPatch(title: "DockApex · 原生菜单遮盖", level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2))
    /// 补底位置（画面已带阴影，遮盖叠阴影时避开）；由应用控制器设置。
    static var patchFrame: (() -> CGRect?)?
    /// 经典模式下藏着的系统 Dock 所在屏。它的格子在屏幕底边外，坐标可能落进下面接着的另一块屏，
    /// 菜单却弹在 Dock 所在屏的底边上，遮盖按这块屏盖；影子模式下为 nil，按格子所在屏。
    static var dockScreen: (() -> NSScreen?)?
    private(set) var lastTiming: [String: Int] = [:]

    func cached(for pid: pid_t) -> NativeDockMenuMirrorContent? {
        guard let entry = cache[pid], ProcessInfo.processInfo.systemUptime - entry.time < 600 else { return nil }
        return entry.content
    }

    /// 读取后回调；失败或超时也回调，菜单照常显示常用项。
    /// 经典模式下只在藏着的系统 Dock 已挪到应用栏所在屏时启用（10-24 实测：打开它的菜单不会把它带出来，
    /// 只有菜单在屏上出现约 20 毫秒，由遮盖盖住）。
    var enabled = true

    func prepare(_ app: AppReference, windowTitles: Set<String>, completion: @escaping @MainActor () -> Void) {
        guard enabled, let running = ShelfAppActions.running(app), cached(for: running.processIdentifier) == nil, !busy,
              AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { completion(); return }
        busy = true
        let pid = running.processIdentifier, path = app.path
        Task { @MainActor in
            // 回调会进入菜单跟踪循环；先释放忙碌标记，菜单中的选择才能执行。
            guard let tile = await Task.detached(priority: .userInitiated, operation: { NativeDockMenuAX.tileFrame(path: path) }).value else {
                self.busy = false; completion(); return
            }
            // 遮盖没能及时盖上就不读：这一次少几个 App 专属项，也不让系统菜单闪出来。
            guard await self.showCover(around: tile, windowTitles: windowTitles) else {
                self.cover.hide(); self.lastTiming["coverTimeout"] = (self.lastTiming["coverTimeout"] ?? 0) + 1
                self.busy = false; completion(); return
            }
            let readStart = ProcessInfo.processInfo.systemUptime
            let entries = await Task.detached(priority: .userInitiated, operation: { NativeDockMenuAX.read(path: path) }).value
            self.lastTiming["read"] = Int((ProcessInfo.processInfo.systemUptime - readStart) * 1000)
            let hideStart = ProcessInfo.processInfo.systemUptime
            await self.hideCover()
            self.lastTiming["hide"] = Int((ProcessInfo.processInfo.systemUptime - hideStart) * 1000)
            if let entries { self.cache[pid] = (ProcessInfo.processInfo.systemUptime, Self.mirror(entries, windowTitles: windowTitles)) }
            self.busy = false
            completion()
        }
    }

    func perform(_ app: AppReference, path titles: [String]) {
        lastTiming["performRequested"] = (lastTiming["performRequested"] ?? 0) + 1
        guard !busy, AXIsProcessTrusted() else { lastTiming["performSkipped"] = (lastTiming["performSkipped"] ?? 0) + 1; return }
        busy = true
        let path = app.path
        Task { @MainActor in
            defer { self.busy = false }
            guard let tile = await Task.detached(priority: .userInitiated, operation: { NativeDockMenuAX.tileFrame(path: path) }).value else { return }
            // 用户选中了原生菜单项：遮盖没盖上也要执行，宁可闪一下也不能吞掉操作。
            _ = await self.showCover(around: tile, windowTitles: [])
            // 自制栏菜单仍在收起时，系统 Dock 打开菜单会失败；等它完全退出跟踪。
            try? await Task.sleep(for: .milliseconds(120))
            let pressed = await Task.detached(priority: .userInitiated, operation: { NativeDockMenuAX.press(path: path, titles: titles) }).value
            self.lastTiming["pressed"] = pressed ? 1 : 0
            await self.hideCover()
            if !pressed { NSSound.beep() }
            if let pid = ShelfAppActions.running(app)?.processIdentifier { self.cache[pid] = nil }
        }
    }

    /// 原生菜单结构：[窗口][分隔][自定义项][分隔][选项▸][分隔][显示所有窗口、隐藏、退出…]。
    static func mirror(_ entries: [NativeDockMenuEntry], windowTitles: Set<String>) -> NativeDockMenuMirrorContent {
        let optionsIndex = entries.lastIndex { !$0.children.isEmpty && ($0.title == "选项" || $0.title == "Options") }
        let head = optionsIndex.map { Array(entries[..<$0]) } ?? []
        var custom = head.filter { $0.isSeparator || !windowTitles.contains($0.title) }
        // 去掉首尾和连续分隔线。
        custom = custom.reduce(into: []) { result, entry in
            if entry.isSeparator, result.last?.isSeparator ?? true { return }
            result.append(entry)
        }
        while custom.last?.isSeparator == true { custom.removeLast() }
        var options = optionsIndex.map { entries[$0] }
        // 自制栏自己管理固定与访达定位；原生“在程序坞中保留”会改动影子 Dock 的固定项，必须排除。
        let excluded: Set<String> = ["在程序坞中保留", "从程序坞中移除", "在访达中显示", "Keep in Dock", "Remove from Dock", "Show in Finder"]
        if var value = options {
            value.children = value.children.filter { !excluded.contains($0.title) }
            while value.children.first?.isSeparator == true { value.children.removeFirst() }
            options = value.children.contains(where: { !$0.isSeparator }) ? value : nil
        }
        let tail = optionsIndex.map { Array(entries[($0 + 1)...]) } ?? []
        let showAll = tail.first { $0.title == "显示所有窗口" || $0.title == "Show All Windows" }
        return NativeDockMenuMirrorContent(custom: custom, options: options, showAllWindows: showAll)
    }

    // MARK: 遮盖

    /// 遮盖用实时捕捉（排除系统 Dock 与它的菜单，保留应用栏和补底），叠上画回的窗口阴影。
    /// 原先是单帧截图：读菜单的一百多毫秒里画面冻住，截图又不带窗口阴影，看起来像整片闪一下、补底边缘露出来。
    /// 返回遮盖是否已经盖上。
    private func showCover(around tile: CGRect, windowTitles: Set<String>) async -> Bool {
        guard let screen = Self.dockScreen?() ?? NSScreen.screens.first(where: { $0.frame.intersects(tile) }) else { return false }
        let full = screen.frame
        // 原生菜单在格子上方水平居中展开，最高到菜单栏下方；宽度随最长的窗口标题变化，
        // 按 13 点字估算再留足余量，至少左右各 460 点。
        let font = NSFont.menuFont(ofSize: 13)
        let widest = windowTitles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let half = max(460, ceil(widest / 2) + 120)
        let minX = max(full.minX, tile.midX - half), maxX = min(full.maxX, tile.midX + half)
        let rect = CGRect(x: minX, y: full.minY, width: maxX - minX, height: full.height)
        let started = ProcessInfo.processInfo.systemUptime
        let own = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let exclusions = Self.patchFrame?().map { [$0] } ?? []
        cover.show(rect: rect, screen: screen, includeApps: true, interactive: false, framesPerSecond: 60,
                   fullResolution: true, existingWindowsOnly: true)
        // 阴影图整列屏幕高，放到后台算，不卡主线程。
        let map = await Task.detached(priority: .userInitiated) {
            let casters = ShadowDockGeometry.shadowCasters(excluding: own, frontmost: frontmost)
            return WindowShadowRenderer.alphaMap(region: rect, scale: 1,
                                                 casters: WindowShadowRenderer.relevant(casters, in: rect), exclusions: exclusions)
        }.value
        cover.setShadowMap(map, region: rect)
        // DockHelper 未运行时遮盖改用较慢的过滤方式（约 0.55 秒），等待时间按它留足。
        let covered = await cover.waitForFirstFrame(timeout: 0.9)
        lastTiming["capture"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        return covered
    }

    private func hideCover() async {
        // 系统菜单取消后有淡出；等它离开屏幕再撤遮盖。
        // 辅助功能树先于菜单窗口就绪，取消或执行后窗口仍可能才上屏并淡出：先等它出现，再等它消失。
        let start = ProcessInfo.processInfo.systemUptime
        var seen = false
        while ProcessInfo.processInfo.systemUptime - start < 1.0 {
            let onScreen = NativeDockMenuAX.dockMenuOnScreen()
            if onScreen { seen = true } else if seen || ProcessInfo.processInfo.systemUptime - start > 0.35 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(16))
        cover.hide()
    }
}

enum NativeDockMenuAX {
    private static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    private static func tile(path: String) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        for list in children(app) where (value(list, kAXRoleAttribute) as? String) == "AXList" {
            for item in children(list) {
                guard let url = value(item, kAXURLAttribute) as? URL ?? (value(item, kAXURLAttribute) as? String).flatMap(URL.init(string:)),
                      url.isFileURL, url.standardizedFileURL.resolvingSymlinksInPath().path == wanted else { continue }
                return item
            }
        }
        return nil
    }

    /// 原生格子的 AppKit 坐标矩形。
    static func tileFrame(path: String) -> CGRect? {
        guard let item = tile(path: path), let p = value(item, kAXPositionAttribute), let s = value(item, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin); AXValueGetValue(s as! AXValue, .cgSize, &size)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width, height: size.height)
    }

    private static func openMenu(_ item: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(item, 0.6)
        let result = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
        guard result == .success || result == .cannotComplete else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let menu = children(item).first(where: { (value($0, kAXRoleAttribute) as? String) == "AXMenu" }), !children(menu).isEmpty { return menu }
            usleep(4_000)
        }
        return nil
    }

    private static func entry(_ element: AXUIElement, depth: Int) -> NativeDockMenuEntry {
        let title = value(element, kAXTitleAttribute) as? String ?? ""
        let enabled = value(element, kAXEnabledAttribute) as? Bool ?? false
        let mark = value(element, "AXMenuItemMarkChar") as? String
        var subitems: [NativeDockMenuEntry] = []
        if depth < 2, let submenu = children(element).first(where: { (value($0, kAXRoleAttribute) as? String) == "AXMenu" }) {
            subitems = children(submenu).map { entry($0, depth: depth + 1) }
        }
        return NativeDockMenuEntry(title: title, enabled: enabled, isSeparator: title.isEmpty && subitems.isEmpty,
                                   checked: !(mark ?? "").isEmpty, children: subitems)
    }

    static func read(path: String) -> [NativeDockMenuEntry]? {
        guard let item = tile(path: path), let menu = openMenu(item) else { return nil }
        let entries = children(menu).map { entry($0, depth: 0) }
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        return entries
    }

    static func press(path: String, titles: [String]) -> Bool {
        guard let item = tile(path: path), let menu = openMenu(item) else { return false }
        var container = menu
        var target: AXUIElement?
        for (index, title) in titles.enumerated() {
            guard let match = children(container).first(where: { (value($0, kAXTitleAttribute) as? String) == title }) else { break }
            if index == titles.count - 1 { target = match; break }
            guard let submenu = children(match).first(where: { (value($0, kAXRoleAttribute) as? String) == "AXMenu" }) else { break }
            container = submenu
        }
        guard let target else { AXUIElementPerformAction(menu, kAXCancelAction as CFString); return false }
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if result != .success { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        return result == .success
    }

    /// 系统 Dock 的菜单窗口位于菜单层。
    static func dockMenuOnScreen() -> Bool {
        // 菜单由 DockHelper 进程绘制。
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { ["DockHelper", "Dock", "程序坞"].contains($0[kCGWindowOwnerName as String] as? String ?? "")
            && ($0[kCGWindowLayer as String] as? Int ?? 0) >= menuLevel - 1 }
    }
}
