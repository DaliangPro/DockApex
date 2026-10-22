import AppKit
import ApplicationServices

/// 只对已运行的 DockParityFixture 发送一次 ShowMenu、Cancel 与指定已知测试动作。
/// 不输出其他应用标题，不读取或保存窗口图像，不修改系统设置。
private actor NativeMenuCapabilityReader {
    private func value(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFTypeRef?
        return (AXUIElementCopyAttributeValue(element, name as CFString, &result), result)
    }
    private func actions(_ element: AXUIElement) -> [String] {
        var result: CFArray?
        guard AXUIElementCopyActionNames(element, &result) == .success else { return [] }
        return result as? [String] ?? []
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute).1 as? [AXUIElement] ?? []
    }
    private func menuInDescendants(_ root: AXUIElement) -> AXUIElement? {
        var queue = children(root).map { ($0, 0) }, cursor = 0
        while cursor < queue.count, cursor < 32 {
            let (element, depth) = queue[cursor]; cursor += 1
            let role = value(element, kAXRoleAttribute).1 as? String
            if role == kAXMenuRole { return element }
            if depth < 2 { queue.append(contentsOf: children(element).prefix(max(0, 32 - queue.count)).map { ($0, depth + 1) }) }
        }
        return nil
    }
    private func shownMenu(_ item: AXUIElement) -> (AXUIElement?, Int32, String) {
        let raw = value(item, "AXShownMenuUIElement")
        if let object = raw.1, CFGetTypeID(object) == AXUIElementGetTypeID() {
            return ((object as! AXUIElement), raw.0.rawValue, "AXShownMenuUIElement")
        }
        if let menu = menuInDescendants(item) { return (menu, raw.0.rawValue, "AXChildren") }
        return (nil, raw.0.rawValue, "none")
    }
    private func state(_ bundle: Bundle) -> [String: Any] {
        guard let directory = bundle.object(forInfoDictionaryKey: "ParityDiagnosticsRoot") as? String,
              let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return ["dockMenuRequests": state["dockMenuRequests"] ?? NSNull(),
                "dockMenuInvocations": state["dockMenuInvocations"] ?? NSNull(),
                "menuChecked": state["menuChecked"] ?? NSNull(), "pid": state["pid"] ?? NSNull()]
    }

    func run(fixtureURL: URL) async -> Data {
        var report: [String: Any] = ["performedUIActions": false, "mutatedSystemSettings": false]
        do {
            let url = fixtureURL.standardizedFileURL.resolvingSymlinksInPath()
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "io.daliang.dockfolders.parityfixture",
                  let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.bundleIdentifier!).first(where: {
                      $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url
                  }), let identity = NativeDockStatusProcess.capture(fixture.processIdentifier, requiresDockPath: false) else {
                throw CheckError("目标不是准确路径下已运行的专用夹具。")
            }
            var resolver = NativeDockStatusProcessResolver()
            guard AXIsProcessTrusted(), let dock = resolver.resolve() else { throw CheckError("缺少已有辅助功能权限或真实系统 Dock。") }
            let application = AXUIElementCreateApplication(dock.pid)
            var queue: [AXUIElement] = [application], cursor = 0
            var item: AXUIElement?
            let deadline = Date().addingTimeInterval(2)
            while cursor < queue.count, cursor < 256, Date() < deadline {
                let element = queue[cursor]; cursor += 1
                let role = value(element, kAXRoleAttribute).1 as? String
                if role == "AXDockItem" {
                    let raw = value(element, kAXURLAttribute).1
                    let candidate = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                    if candidate?.standardizedFileURL.resolvingSymlinksInPath() == url { item = element; break }
                } else if ["AXApplication", "AXList", "AXGroup", "AXScrollArea"].contains(role ?? "") {
                    queue.append(contentsOf: children(element).prefix(max(0, 256 - queue.count)))
                }
            }
            guard let item, actions(item).contains(kAXShowMenuAction) else { throw CheckError("未找到准确原生 Dock 入口或 ShowMenu 动作。") }
            let initialShown = value(item, "AXShownMenuUIElement")
            let initialChildrenMenu = menuInDescendants(item)
            report["initialShownMenuAXResult"] = initialShown.0.rawValue
            report["initialShownMenuIsElement"] = initialShown.1.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
            report["initialChildrenContainMenu"] = initialChildrenMenu != nil
            // 只接管准确夹具已暴露的菜单，绝不由静态 children 推断它正在 tracking。
            var existingShown: AXUIElement?
            if initialShown.0 == .success, let element = initialShown.1, CFGetTypeID(element) == AXUIElementGetTypeID() {
                existingShown = (element as! AXUIElement)
            } else if initialShown.0 != .noValue && initialShown.0 != .attributeUnsupported && initialShown.0 != .success {
                throw CheckError("原生菜单前置状态暂不可读（AX \(initialShown.0.rawValue)），未发送动作；未把它当作已显示菜单。")
            }
            guard NativeDockStatusProcess.capture(identity.pid, requiresDockPath: false) == identity,
                  NativeDockStatusProcess.capture(dock.pid) == dock else { throw CheckError("进程身份已变化。") }
            report["before"] = state(bundle)
            report["usedExistingFixtureMenu"] = existingShown != nil
            report["showMenuSent"] = existingShown == nil
            if existingShown == nil {
                let showStart = Date()
                let shown = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
                report["performedUIActions"] = true
                report["showMenuAXResult"] = shown.rawValue
                report["showMenuMilliseconds"] = Date().timeIntervalSince(showStart) * 1000
            }
            let readDeadline = Date().addingTimeInterval(1)
            var reading = existingShown.map { ($0 as AXUIElement?, initialShown.0.rawValue, "existingAXShownMenuUIElement") } ?? shownMenu(item)
            var attempts = 1
            while reading.0 == nil, Date() < readDeadline, attempts < 12 {
                try await Task.sleep(for: .milliseconds(50))
                reading = shownMenu(item); attempts += 1
            }
            report["shownMenuReadResult"] = reading.1
            report["menuReadAttempts"] = attempts
            report["menuReadSource"] = reading.2
            report["afterShow"] = state(bundle)
            guard let menu = reading.0 else {
                report["directChildRolesAfterShow"] = children(item).map { value($0, kAXRoleAttribute).1 as? String ?? "unknown" }
                throw CheckError("单次 ShowMenu 后，限时轮询属性与子元素仍未取得菜单；需主操作者检查并按 Esc。")
            }
            report["menuActions"] = actions(menu)
            let entries = children(menu)
            report["topLevelItemCount"] = entries.count
            let known = entries.filter { (value($0, kAXTitleAttribute).1 as? String)?.hasPrefix("Parity ") == true }
            report["knownFixtureItemCount"] = known.count
            guard let action = known.first(where: { value($0, kAXTitleAttribute).1 as? String == "Parity 动作 +1" }) else {
                throw CheckError("真实菜单未包含夹具预定义动作；不猜测条目。")
            }
            report["retainedActionNamesBeforeCancel"] = actions(action)
            guard actions(menu).contains(kAXCancelAction) else { throw CheckError("原生 AXMenu 未暴露 Cancel；不尝试模拟按键，需主操作者按 Esc。") }
            let cancelled = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            report["performedUIActions"] = true
            report["cancelAXResult"] = cancelled.rawValue
            let cancelDeadline = Date().addingTimeInterval(1)
            var afterCancel = value(item, "AXShownMenuUIElement")
            var cancelReadAttempts = 1
            while afterCancel.0 != .noValue, Date() < cancelDeadline, cancelReadAttempts < 12 {
                try await Task.sleep(for: .milliseconds(50))
                afterCancel = value(item, "AXShownMenuUIElement"); cancelReadAttempts += 1
            }
            report["shownMenuAfterCancel"] = afterCancel.0.rawValue
            report["cancelReadAttempts"] = cancelReadAttempts
            report["staticChildrenMenuRetainedAfterCancel"] = menuInDescendants(item) != nil
            // children 可以保留缓存；只用明确 AXShownMenuUIElement=noValue 确认显示状态消失。
            guard afterCancel.0 == .noValue else { throw CheckError("取消后未得到明确的 shown-menu=noValue，无法确认原生 tracking 已退出，拒绝继续转发。") }
            report["retainedActionNamesAfterCancel"] = actions(action)
            report["retainedActionRoleAfterCancel"] = value(action, kAXRoleAttribute).0.rawValue
            guard NativeDockStatusProcess.capture(identity.pid, requiresDockPath: false) == identity,
                  NativeDockStatusProcess.capture(dock.pid) == dock else { throw CheckError("动作前进程身份已变化。") }
            // 对刚刚读取并保留的真实 AX 对象只发一次 Press，不按标题重新查找或重开菜单。
            let pressed = AXUIElementPerformAction(action, kAXPressAction as CFString)
            report["retainedActionPressResult"] = pressed.rawValue
            try await Task.sleep(for: .milliseconds(300))
            report["after"] = state(bundle)
            report["nativeMenuClosedAfterForwarding"] = value(item, "AXShownMenuUIElement").0 == .noValue
            let before = report["before"] as? [String: Any]
            let after = report["after"] as? [String: Any]
            if let beforeCount = before?["dockMenuInvocations"] as? Int, let afterCount = after?["dockMenuInvocations"] as? Int,
               before?["pid"] as? Int == Int(identity.pid), after?["pid"] as? Int == Int(identity.pid) {
                report["knownActionReturnedExactlyOnce"] = afterCount == beforeCount + 1
            } else { report["knownActionReturnedExactlyOnce"] = false }
        } catch { report["error"] = error.localizedDescription }
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

@MainActor
private final class NativeMenuHarnessController: NSObject, NSApplicationDelegate {
    private let reader = NativeMenuCapabilityReader()
    private var window: NSWindow!
    private var status: NSTextField!
    private var runButton: NSButton!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 330),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "原生专属菜单能力检查"
        window.isReleasedWhenClosed = false
        let description = NSTextField(wrappingLabelWithString: "仅操作已运行的 DockParityFixture。\n点击后依次读取真实菜单、取消原生 tracking，再向保留的真实 AX 菜单项发送一次“+1”。不保存窗口图像或用户菜单标题。")
        description.frame = NSRect(x: 24, y: 225, width: 512, height: 80)
        window.contentView?.addSubview(description)
        runButton = NSButton(title: "验证菜单取消与动作回传", target: self, action: #selector(runCheck))
        runButton.bezelStyle = .rounded
        runButton.frame = NSRect(x: 24, y: 175, width: 512, height: 36)
        window.contentView?.addSubview(runButton)
        status = NSTextField(wrappingLabelWithString: "等待主操作者点击。若退出原生 tracking 无法确认，请按 Esc 后查看结果。")
        status.frame = NSRect(x: 24, y: 72, width: 512, height: 84)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        window.contentView?.addSubview(status)
        let quit = NSButton(title: "退出验证器", target: self, action: #selector(quitHarness))
        quit.bezelStyle = .rounded; quit.frame = NSRect(x: 24, y: 20, width: 512, height: 34)
        window.contentView?.addSubview(quit)
        let appMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let actions = NSMenu()
        actions.addItem(withTitle: "退出验证器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = actions; appMenu.addItem(applicationItem); NSApp.mainMenu = appMenu
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc private func quitHarness() { NSApp.terminate(nil) }
    @objc private func runCheck() {
        guard runButton.isEnabled,
              let fixture = Bundle.main.object(forInfoDictionaryKey: "FixtureAppPath") as? String,
              let output = Bundle.main.object(forInfoDictionaryKey: "DiagnosticsRoot") as? String else { return }
        runButton.isEnabled = false
        status.stringValue = "正在验证，只向专用夹具发送一次菜单请求与一次已知动作。"
        Task { @MainActor in
            let data = await reader.run(fixtureURL: URL(fileURLWithPath: fixture))
            do {
                let report = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("native-menu-capability-v3.json"), options: .atomic)
                if let error = report["error"] as? String { status.stringValue = "检查未通过：\(error)" }
                else { status.stringValue = "检查完成。原生菜单关闭：\(report["nativeMenuClosedAfterForwarding"] ?? false)\n“+1”准确回传一次：\(report["knownActionReturnedExactlyOnce"] ?? false)" }
            } catch { status.stringValue = "记录失败：\(error.localizedDescription)" }
            runButton.isEnabled = true
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum NativeMenuCapabilityChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = NativeMenuHarnessController()
        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.run()
        withExtendedLifetime(controller) {}
    }
}
