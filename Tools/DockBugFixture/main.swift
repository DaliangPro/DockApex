import AppKit
import CoreGraphics
import Foundation

/// 只操作本夹具的两个窗口；不读取其他应用、不申请权限、不修改 Dock 设置。
@MainActor
final class DockBugFixtureController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var control: NSWindow!
    private var specimen: NSWindow!
    private var status: NSTextField!
    private var events: [[String: Any]] = []
    private var pendingMiniaturizations: [Int: TimeInterval] = [:]
    private var restoreRequests: [Int: TimeInterval] = [:]
    private let session = UUID().uuidString
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var isWriting = false
    private var pendingWrite: Timer?

    private var output: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "BugFixtureDiagnosticsRoot") as? String
        return URL(fileURLWithPath: configured ?? FileManager.default.currentDirectoryPath + "/Data/Diagnostics/五项修复-fixture", isDirectory: true)
            .appendingPathComponent("events.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        specimen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        specimen.title = "Dock 五项修复 · 标准测试窗"
        specimen.setAccessibilityIdentifier("dock-bug-specimen")
        specimen.isReleasedWhenClosed = false
        specimen.minSize = CGSize(width: 320, height: 220)
        specimen.collectionBehavior = [.fullScreenPrimary]
        specimen.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.58, alpha: 1)
        let description = NSTextField(wrappingLabelWithString: "标准可调整窗口\n可使用系统黄色按钮或 ⌘M 最小化。\n本窗口只用于 Dock 动画、占位和多显示器验收。")
        description.font = .systemFont(ofSize: 19, weight: .medium)
        description.textColor = .white
        description.alignment = .center
        description.frame = CGRect(x: 24, y: 80, width: 552, height: 180)
        description.autoresizingMask = [.width, .height]
        specimen.contentView?.addSubview(description)
        specimen.delegate = self
        specimen.center()
        specimen.orderFront(nil)
        makeControl()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        append("fixture-launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        frontControl()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        append("fixture-terminating")
        pendingWrite?.invalidate(); pendingWrite = nil
        write()
    }

    private func makeMenu() {
        let menu = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "退出 Dock 五项修复夹具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem(); applicationItem.submenu = application; menu.addItem(applicationItem)
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullscreen = NSMenuItem(title: "测试窗切换全屏幕", action: #selector(toggleTestFullscreen), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.target = self
        window.addItem(fullscreen)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = window; menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = window
    }

    private func makeControl() {
        control = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 410, height: 410),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        control.title = "Dock 五项修复 · 控制窗"
        control.setAccessibilityIdentifier("dock-bug-control")
        control.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 410, height: 410))
        let note = NSTextField(wrappingLabelWithString: "仅操作本夹具窗口；事件包含显示器可用区域、窗口状态与系统最小化回调时间。")
        note.frame = CGRect(x: 20, y: 353, width: 370, height: 42)
        note.font = .systemFont(ofSize: 12)
        content.addSubview(note)
        let controls: [(String, Selector)] = [
            ("测试窗填满主显示器可用区域", #selector(fillPrimary)),
            ("测试窗填满内屏可用区域", #selector(fillBuiltIn)),
            ("测试窗最小化", #selector(minimizeSpecimen)),
            ("恢复测试窗", #selector(restoreSpecimen)),
            ("把控制窗前台", #selector(frontControl)),
            ("记录当前窗口与显示器快照", #selector(exportSnapshot)),
            ("退出夹具", #selector(quitFixture))
        ]
        for (index, item) in controls.enumerated() {
            let button = NSButton(title: item.0, target: self, action: item.1)
            button.bezelStyle = .rounded
            button.frame = CGRect(x: 20, y: 309 - CGFloat(index) * 39, width: 370, height: 30)
            button.identifier = NSUserInterfaceItemIdentifier("fixture-control-\(index)")
            content.addSubview(button)
        }
        status = NSTextField(wrappingLabelWithString: "等待测试。")
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.frame = CGRect(x: 20, y: 12, width: 370, height: 54)
        content.addSubview(status)
        control.contentView = content
        control.delegate = self
        control.center()
        control.makeKeyAndOrderFront(nil)
    }

    @objc private func fillPrimary() {
        let primary = NSScreen.screens.first { displayID($0) == CGMainDisplayID() } ?? NSScreen.screens.first
        fill(primary, action: "fill-primary-visible-frame")
    }

    @objc private func fillBuiltIn() {
        let builtIn = NSScreen.screens.first { CGDisplayIsBuiltin(displayID($0)) != 0 }
            ?? NSScreen.screens.first { screen in
                let name = screen.localizedName.lowercased()
                return ["内建", "内置", "built-in", "built in"].contains { name.contains($0) }
            }
        guard let builtIn else { append("built-in-display-unavailable"); return }
        fill(builtIn, action: "fill-built-in-visible-frame")
    }

    private func fill(_ screen: NSScreen?, action: String) {
        guard let screen else { append("display-unavailable"); return }
        if specimen.styleMask.contains(.fullScreen) {
            append("fill-refused-while-fullscreen", extra: ["instruction": "请先退出测试窗全屏幕，再执行填满可用区域。"])
            return
        }
        if specimen.isMiniaturized { restoreRequests[specimen.windowNumber] = now; specimen.deminiaturize(nil) }
        specimen.setFrame(screen.visibleFrame, display: true)
        specimen.makeKeyAndOrderFront(nil)
        append(action, extra: ["targetDisplayUUID": displayUUID(screen), "targetVisibleFrame": rect(screen.visibleFrame)])
    }

    @objc private func minimizeSpecimen() {
        guard !specimen.isMiniaturized else { append("minimize-noop-already-miniaturized"); return }
        specimen.makeKeyAndOrderFront(nil)
        append("minimize-request", window: specimen)
        specimen.miniaturize(nil)
    }

    @objc private func restoreSpecimen() {
        restoreRequests[specimen.windowNumber] = now
        append("restore-request", window: specimen)
        if specimen.isMiniaturized { specimen.deminiaturize(nil) }
        else { restoreRequests.removeValue(forKey: specimen.windowNumber) }
        specimen.makeKeyAndOrderFront(nil)
    }

    @objc private func frontControl() {
        if control.isMiniaturized { restoreRequests[control.windowNumber] = now; control.deminiaturize(nil) }
        control.makeKeyAndOrderFront(nil)
        NSApp.activate()
        append("control-front")
    }

    @objc private func toggleTestFullscreen() { specimen.toggleFullScreen(nil) }
    @objc private func exportSnapshot() { append("manual-snapshot") }
    @objc private func quitFixture() { NSApp.terminate(nil) }
    @objc private func screensChanged() { append("screen-parameters-changed") }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func windowWillMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        pendingMiniaturizations[window.windowNumber] = now
        append("windowWillMiniaturize", window: window, extra: ["durationMs": 0, "durationBasis": "本次最小化开始"])
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let duration = pendingMiniaturizations.removeValue(forKey: window.windowNumber).map { (now - $0) * 1000 }
        append("windowDidMiniaturize", window: window,
               extra: ["durationMs": duration as Any? ?? NSNull(), "durationBasis": "windowWillMiniaturize 至 windowDidMiniaturize"])
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let duration = restoreRequests.removeValue(forKey: window.windowNumber).map { (now - $0) * 1000 }
        append("windowDidDeminiaturize", window: window,
               extra: ["durationMs": duration as Any? ?? NSNull(),
                       "durationBasis": duration == nil ? "外部恢复无开始回调，无法独立测量恢复动画时长" : "本夹具恢复请求至 windowDidDeminiaturize"])
    }

    func windowDidMove(_ notification: Notification) { recordWindowEvent("windowDidMove", notification) }
    func windowDidResize(_ notification: Notification) { recordWindowEvent("windowDidResize", notification) }
    func windowDidChangeScreen(_ notification: Notification) { recordWindowEvent("windowDidChangeScreen", notification) }
    func windowWillEnterFullScreen(_ notification: Notification) { recordWindowEvent("windowWillEnterFullScreen", notification) }
    func windowDidEnterFullScreen(_ notification: Notification) { recordWindowEvent("windowDidEnterFullScreen", notification) }
    func windowWillExitFullScreen(_ notification: Notification) { recordWindowEvent("windowWillExitFullScreen", notification) }
    func windowDidExitFullScreen(_ notification: Notification) { recordWindowEvent("windowDidExitFullScreen", notification) }
    func windowWillClose(_ notification: Notification) { recordWindowEvent("windowWillClose", notification) }

    private func recordWindowEvent(_ name: String, _ notification: Notification) {
        append(name, window: notification.object as? NSWindow)
    }

    private func append(_ name: String, window: NSWindow? = nil, extra: [String: Any] = [:]) {
        guard !isWriting else { return }
        let instant = now
        var event: [String: Any] = ["event": name, "sessionID": session, "uptimeSeconds": instant,
                                    "sinceLaunchMs": (instant - startedAt) * 1000,
                                    "timeUTC": ISO8601DateFormatter().string(from: Date()),
                                    "windows": ownWindows(), "screens": screens()]
        if let window { event["windowNumber"] = window.windowNumber; event["windowTitle"] = window.title }
        for (key, value) in extra { event[key] = value }
        events.append(event)
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
        let measured = (extra["durationMs"] as? Double).map { String(format: " · %.1f ms", $0) } ?? ""
        status?.stringValue = "\(name)\(measured)\n\(events.count) 条记录 · 仅本夹具窗口"
        // 合并同一轮窗口通知，避免在 willMiniaturize 回调中同步落盘干扰时长测量。
        guard pendingWrite == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingWrite = nil
                self.write()
            }
        }
        pendingWrite = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func write() {
        isWriting = true
        defer { isWriting = false }
        let snapshot: [String: Any] = ["schemaVersion": 1, "sessionID": session,
                                       "bundleID": Bundle.main.bundleIdentifier ?? "",
                                       "processID": ProcessInfo.processInfo.processIdentifier,
                                       "screenCapturePreflight": CGPreflightScreenCaptureAccess(),
                                       "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                       "screens": screens(), "windows": ownWindows(), "events": events]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        } catch {
            status?.stringValue = "记录失败：\(error.localizedDescription)"
        }
    }

    private func ownWindows() -> [[String: Any]] {
        [control, specimen].compactMap { window in
            guard let window else { return nil }
            return ["windowNumber": window.windowNumber, "title": window.title, "frame": rect(window.frame),
                    "visible": window.isVisible, "miniaturized": window.isMiniaturized,
                    "fullscreen": window.styleMask.contains(.fullScreen), "key": window.isKeyWindow,
                    "screenUUID": window.screen.map(displayUUID) as Any? ?? NSNull()]
        }
    }

    private func screens() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            let id = displayID(screen)
            return ["displayID": id, "displayUUID": displayUUID(screen), "name": screen.localizedName,
                    "isPrimary": id == CGMainDisplayID(), "builtIn": CGDisplayIsBuiltin(id) != 0,
                    "frame": rect(screen.frame), "visibleFrame": rect(screen.visibleFrame),
                    "backingScale": screen.backingScaleFactor]
        }
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func displayUUID(_ screen: NSScreen) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID(screen))?.takeRetainedValue() else { return "display-\(displayID(screen))" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func rect(_ rect: CGRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }
}

@main
struct DockBugFixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = DockBugFixtureController()
        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.run()
        withExtendedLifetime(controller) {}
    }
}
