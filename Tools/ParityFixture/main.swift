import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
final class ParityFixtureController: NSObject, NSApplicationDelegate {
    private var console: NSWindow!
    private var windowA: NSWindow!
    private var windowB: NSWindow!
    private var floating: NSPanel?
    private var statusLabel: NSTextField!
    private var badge = "7"
    private var customContent = false
    private var checked = false
    private var menuRequests = 0
    private var menuInvocations = 0
    private var snapshotNumber = 0
    private var lastAction: [String: Any] = [:]
    private var diagnostics: URL {
        let path = Bundle.main.object(forInfoDictionaryKey: "ParityDiagnosticsRoot") as? String
            ?? FileManager.default.currentDirectoryPath + "/Data/Diagnostics/ParityFixture"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMainMenu()
        NSApp.applicationIconImage = baseIcon()
        NSApp.dockTile.badgeLabel = badge
        windowA = documentWindow(title: "Parity 测试窗 A", origin: NSPoint(x: 120, y: 240), color: .systemTeal)
        windowB = documentWindow(title: "Parity 测试窗 B", origin: NSPoint(x: 580, y: 240), color: .systemOrange)
        makeConsole()
        capture("fixture-launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        console.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        floating?.orderOut(nil)
        writeState()
    }

    private func makeMainMenu() {
        let menu = NSMenu()
        let root = NSMenuItem()
        let application = NSMenu()
        application.addItem(withTitle: "退出原生能力夹具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = application
        menu.addItem(root)
        NSApp.mainMenu = menu
    }

    private func documentWindow(title: String, origin: NSPoint, color: NSColor) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 440, height: 300)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = color.withAlphaComponent(0.18)
        let label = NSTextField(labelWithString: title + "\n可在本窗口执行系统最小化或跨 Space 操作。")
        label.alignment = .center
        label.font = .systemFont(ofSize: 20)
        label.frame = NSRect(x: 20, y: 110, width: 400, height: 70)
        window.contentView?.addSubview(label)
        window.orderFront(nil)
        return window
    }

    private func makeConsole() {
        console = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 585),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        console.title = "原生能力夹具 · 控制台"
        console.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 585))
        let heading = NSTextField(wrappingLabelWithString: "所有可见操作由 CUA 点击按钮触发。只操作本夹具的窗口、菜单和 Dock 图块，不修改系统 Dock 设置。")
        heading.frame = NSRect(x: 22, y: 516, width: 496, height: 52)
        heading.font = .systemFont(ofSize: 13)
        content.addSubview(heading)
        let controls: [(String, Selector)] = [
            ("导出只读快照", #selector(exportSnapshot)),
            ("切换浮动测试栏（工作区对照）", #selector(toggleFloating)),
            ("A：最小化", #selector(minimizeA)),
            ("A：通过 AX 取消最小化并提升", #selector(restoreAWithAX)),
            ("B：通过 AX 提升", #selector(raiseBWithAX)),
            ("A：铺满系统可用区", #selector(fillA)),
            ("切换角标：7 / 23", #selector(toggleBadge)),
            ("切换自绘 Dock 图块", #selector(toggleCustomContent)),
            ("退出夹具", #selector(quitFixture))
        ]
        for (index, entry) in controls.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: entry.1)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 24, y: 470 - CGFloat(index) * 42, width: 492, height: 32)
            content.addSubview(button)
        }
        statusLabel = NSTextField(wrappingLabelWithString: "等待操作；初始角标 7，两个测试窗口。")
        statusLabel.frame = NSRect(x: 24, y: 16, width: 492, height: 60)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.addSubview(statusLabel)
        console.contentView = content
        console.center()
        console.makeKeyAndOrderFront(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuRequests += 1
        writeState()
        let menu = NSMenu(title: "Parity 专属菜单")
        menu.autoenablesItems = false
        let action = NSMenuItem(title: "Parity 动作 +1", action: #selector(menuAction), keyEquivalent: "")
        action.target = self
        menu.addItem(action)
        let check = NSMenuItem(title: "Parity 切换选中", action: #selector(menuToggle), keyEquivalent: "")
        check.target = self
        check.state = checked ? .on : .off
        menu.addItem(check)
        let disabled = NSMenuItem(title: "Parity 禁用项", action: nil, keyEquivalent: "")
        disabled.isEnabled = false
        menu.addItem(disabled)
        let child = NSMenuItem(title: "Parity 测试近期文档", action: nil, keyEquivalent: "")
        let recent = NSMenu()
        for title in ["Parity Example A.txt", "Parity Example B.txt"] {
            let item = NSMenuItem(title: title, action: #selector(menuAction), keyEquivalent: "")
            item.target = self
            recent.addItem(item)
        }
        child.submenu = recent
        menu.addItem(child)
        return menu
    }

    @objc private func menuAction() {
        menuInvocations += 1
        capture("dock-menu-action")
    }

    @objc private func menuToggle() {
        checked.toggle()
        capture("dock-menu-check-toggle")
    }

    @objc private func exportSnapshot() { capture("manual-export") }

    @objc private func toggleFloating() {
        if floating?.isVisible == true {
            floating?.orderOut(nil)
        } else {
            if floating == nil {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Parity 浮动测试栏"
                panel.level = .floating
                panel.backgroundColor = .systemPink
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
                let label = NSTextField(labelWithString: "浮动测试栏：系统是否预留此区域？")
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 18)
                label.frame = NSRect(x: 15, y: 35, width: 420, height: 28)
                panel.contentView?.addSubview(label)
                floating = panel
            }
            let visible = console.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            floating?.setFrame(NSRect(x: visible.midX - 230, y: visible.minY + 4, width: 460, height: 100), display: true)
            floating?.orderFrontRegardless()
        }
        capture("floating-toggle")
    }

    @objc private func minimizeA() {
        windowA.miniaturize(nil)
        capture("window-a-miniaturized")
    }

    @objc private func fillA() {
        if windowA.isMiniaturized { windowA.deminiaturize(nil) }
        let visible = windowA.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        windowA.setFrame(visible, display: true)
        windowA.makeKeyAndOrderFront(nil)
        capture("window-a-filled-visible-frame")
    }

    private func ownAXWindow(_ title: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        let (_, value) = NativeParityProbe.attribute(app, kAXWindowsAttribute as String)
        return (value as? [AXUIElement])?.first { NativeParityProbe.string($0, "AXTitle") == title }
    }

    @objc private func restoreAWithAX() {
        guard let element = ownAXWindow(windowA.title) else { lastAction = ["error": "未取得本夹具窗口 AX 元素"]; capture("ax-a-missing"); return }
        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable)
        let restore = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let raise = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        lastAction = ["targetPID": getpid(), "target": "本夹具窗口 A", "settableError": NativeParityProbe.errorName(check),
                      "minimizedSettable": settable.boolValue, "setMinimizedFalse": NativeParityProbe.errorName(restore),
                      "raise": NativeParityProbe.errorName(raise), "afterMinimized": windowA.isMiniaturized]
        capture("ax-restore-a")
    }

    @objc private func raiseBWithAX() {
        guard let element = ownAXWindow(windowB.title) else { lastAction = ["error": "未取得本夹具窗口 AX 元素"]; capture("ax-b-missing"); return }
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        lastAction = ["targetPID": getpid(), "target": "本夹具窗口 B", "raise": NativeParityProbe.errorName(raised)]
        capture("ax-raise-b")
    }

    @objc private func toggleBadge() {
        badge = badge == "7" ? "23" : "7"
        NSApp.dockTile.badgeLabel = badge
        capture("badge-" + badge)
    }

    @objc private func toggleCustomContent() {
        customContent.toggle()
        NSApp.dockTile.contentView = customContent ? ParityDockContent(frame: NSRect(x: 0, y: 0, width: 128, height: 128)) : nil
        NSApp.dockTile.display()
        capture("custom-dock-content-toggle")
    }

    @objc private func quitFixture() { NSApp.terminate(nil) }

    private func writeState() {
        let state: [String: Any] = ["pid": getpid(), "badge": badge, "customDockContent": customContent,
                                  "dockMenuRequests": menuRequests, "dockMenuInvocations": menuInvocations,
                                  "menuChecked": checked, "floatingVisible": floating?.isVisible ?? false,
                                  "windowAMinimized": windowA?.isMiniaturized ?? false,
                                  "windowBMinimized": windowB?.isMiniaturized ?? false,
                                  "screens": NativeParityProbe.screens(), "lastAction": lastAction,
                                  "mutatedSystemPreferences": false]
        try? NativeParityProbe.write(state, to: diagnostics.appendingPathComponent("state.json"))
    }

    private func capture(_ tag: String) {
        snapshotNumber += 1
        writeState()
        var options = NativeParityProbe.Options()
        options.windowPID = getpid()
        options.ownerPIDs = [getpid()]
        options.tag = tag
        let product = NSRunningApplication.runningApplications(withBundleIdentifier: "io.daliang.dockfolders").first
        if let product { options.ownerPIDs.insert(product.processIdentifier) }
        let path = diagnostics.appendingPathComponent(String(format: "%03d-%@.json", snapshotNumber, tag))
        do {
            var result = NativeParityProbe.snapshot(options)
            result["fixtureLastAction"] = lastAction
            result["fixtureBadge"] = badge
            result["fixtureCustomDockContent"] = customContent
            try NativeParityProbe.write(result, to: path)
            statusLabel?.stringValue = "\(tag)；AXTrusted=\(AXIsProcessTrusted())\n诊断：\(path.lastPathComponent)"
        } catch { statusLabel?.stringValue = "诊断写入失败：\(error.localizedDescription)" }
    }

    private func baseIcon() -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 24, yRadius: 24).fill()
            ("P" as NSString).draw(at: NSPoint(x: 38, y: 24), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 74), .foregroundColor: NSColor.white])
            return true
        }
    }
}

@MainActor
private final class ParityDockContent: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: bounds).fill()
        ("PX" as NSString).draw(at: NSPoint(x: 13, y: 31), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 54), .foregroundColor: NSColor.black])
    }
}

@main
struct ParityFixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ParityFixtureController()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
