import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// 只读诊断。此文件不调用鼠标事件投递、AX 动作或 Dock 偏好写入。
@MainActor
enum NativeParityProbe {
    struct Options {
        var label = "DockParityFixture"
        var windowPID: pid_t?
        var ownerPIDs: Set<pid_t> = []
        var includeVisibleMenus = false
        var output: URL?
        var tag = "只读快照"
    }

    static func rect(_ value: CGRect) -> [String: Double] {
        ["x": Double(value.minX), "y": Double(value.minY),
         "width": Double(value.width), "height": Double(value.height)]
    }

    static func screens() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            ["name": screen.localizedName,
             "displayID": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? -1,
             "frame": rect(screen.frame), "visibleFrame": rect(screen.visibleFrame),
             "scale": Double(screen.backingScaleFactor)]
        }
    }

    static func errorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .apiDisabled: return "apiDisabled"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .cannotComplete: return "cannotComplete"
        case .invalidUIElement: return "invalidUIElement"
        case .notImplemented: return "notImplemented"
        case .noValue: return "noValue"
        default: return "AXError(\(error.rawValue))"
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name).1 as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String).1 as? [AXUIElement] ?? []
    }

    static func simplified(_ value: CFTypeRef?) -> Any {
        guard let value else { return NSNull() }
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() { return (value as? NSNumber)?.boolValue ?? false }
        if let text = value as? String { return String(text.prefix(512)) }
        if let number = value as? NSNumber { return number }
        if let url = value as? URL { return url.absoluteString }
        if type == AXValueGetTypeID() {
            let ax = value as! AXValue
            switch AXValueGetType(ax) {
            case .cgPoint:
                var point = CGPoint.zero
                if AXValueGetValue(ax, .cgPoint, &point) { return ["x": Double(point.x), "y": Double(point.y)] }
            case .cgSize:
                var size = CGSize.zero
                if AXValueGetValue(ax, .cgSize, &size) { return ["width": Double(size.width), "height": Double(size.height)] }
            case .cgRect:
                var rectangle = CGRect.zero
                if AXValueGetValue(ax, .cgRect, &rectangle) { return rect(rectangle) }
            default: break
            }
            return "AXValue(type=\(AXValueGetType(ax).rawValue))"
        }
        if type == AXUIElementGetTypeID() { return "AXUIElement" }
        if let array = value as? [Any] { return ["count": array.count] }
        return "CFTypeID(\(type))"
    }

    static func describe(_ element: AXUIElement, allowTitle: Bool = true) -> [String: Any] {
        var names: CFArray?
        let namesError = AXUIElementCopyAttributeNames(element, &names)
        var actions: CFArray?
        let actionsError = AXUIElementCopyActionNames(element, &actions)
        var result: [String: Any] = [
            "attributeNamesError": errorName(namesError),
            "attributeNames": names as? [String] ?? [],
            "actionsError": errorName(actionsError), "actions": actions as? [String] ?? []
        ]
        var properties: [String: Any] = [:]
        let requested = ["AXRole", "AXSubrole", "AXRoleDescription", "AXIdentifier", "AXHelp", "AXDescription",
                         "AXStatusLabel", "AXProgressValue", "AXShownMenuUIElement", "AXIsApplicationRunning",
                         "AXValue", "AXURL", "AXPosition", "AXSize", "AXMinimized", "AXMain", "AXEnabled"]
            + (allowTitle ? ["AXTitle"] : [])
        for name in requested {
            let (error, value) = attribute(element, name)
            properties[name] = ["error": errorName(error), "value": simplified(value)]
        }
        for name in ["AXMinimized", "AXMain", "AXPosition", "AXSize"] {
            var settable = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            properties[name + "Settable"] = ["error": errorName(error), "value": settable.boolValue]
        }
        result["properties"] = properties
        return result
    }

    static func menuTree(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
        AXUIElementSetMessagingTimeout(element, 0.3)
        var result: [String: Any] = ["role": string(element, "AXRole") ?? "", "title": string(element, "AXTitle") ?? ""]
        var properties: [String: Any] = [:]
        for name in ["AXPosition", "AXSize", "AXEnabled", "AXValue"] {
            let (error, value) = attribute(element, name)
            properties[name] = ["error": errorName(error), "value": simplified(value)]
        }
        result["properties"] = properties
        if depth < 5 { result["children"] = children(element).prefix(60).map { menuTree($0, depth: depth + 1) } }
        return result
    }

    static func dock(_ options: Options) -> [String: Any] {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return ["error": "没有找到系统 Dock 进程"]
        }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var matched: [[String: Any]] = []
        var menus: [[String: Any]] = []
        var dockItemCount = 0
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 4, visited < 350 else { return }
            visited += 1
            let role = string(element, "AXRole") ?? ""
            let title = string(element, "AXTitle") ?? ""
            if role == "AXDockItem" {
                dockItemCount += 1
                let identityText = [title, string(element, "AXDescription") ?? "",
                                    String(describing: simplified(attribute(element, "AXURL").1))].joined(separator: " ")
                if options.label.isEmpty || identityText.localizedCaseInsensitiveContains(options.label) {
                    var item = describe(element)
                    let direct = children(element)
                    item["directChildrenCount"] = direct.count
                    item["directChildRoles"] = direct.map { string($0, "AXRole") ?? "" }
                    item["menuDescendantWithoutInvokingAction"] = direct.contains { string($0, "AXRole") == "AXMenu" }
                    let (shownError, shownValue) = attribute(element, "AXShownMenuUIElement")
                    item["shownMenuAttributeError"] = errorName(shownError)
                    if let shownValue, CFGetTypeID(shownValue) == AXUIElementGetTypeID() {
                        item["shownMenuAttributeTree"] = menuTree(shownValue as! AXUIElement)
                    }
                    matched.append(item)
                }
            }
            if role == "AXMenu", options.includeVisibleMenus {
                menus.append(menuTree(element))
                return
            }
            for child in children(element) { walk(child, depth: depth + 1) }
        }
        walk(app, depth: 0)
        let (rootError, _) = attribute(app, "AXChildren")
        return ["pid": process.processIdentifier, "rootChildrenError": errorName(rootError),
                "filter": options.label, "visitedElements": visited, "dockItemCount": dockItemCount,
                "matchedItems": matched, "visibleMenus": menus,
                "performedAction": false, "requestedMenuPresentation": false]
    }

    static func windows(_ pid: pid_t) -> [String: Any] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let (error, value) = attribute(app, kAXWindowsAttribute as String)
        let windows = value as? [AXUIElement] ?? []
        return ["pid": pid, "error": errorName(error), "windowCount": windows.count,
                "windows": windows.map { describe($0) }, "performedAction": false]
    }

    static func ownCGWindows(_ owners: Set<pid_t>) -> [[String: Any]] {
        guard !owners.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int, owners.contains(pid_t(pid)) else { return nil }
            var output: [String: Any] = [:]
            for key in [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowLayer, kCGWindowBounds, kCGWindowIsOnscreen, kCGWindowName] {
                if let value = row[key as String] { output[key as String] = value }
            }
            return output
        }
    }

    static func snapshot(_ options: Options) -> [String: Any] {
        var preferences: [String: Any] = [:]
        for key in ["autohide", "autohide-delay", "orientation"] {
            preferences[key] = simplified(CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString))
        }
        var result: [String: Any] = [
            "version": 1, "tag": options.tag, "createdAtUTC": ISO8601DateFormatter().string(from: Date()),
            "callerPID": ProcessInfo.processInfo.processIdentifier, "callerBundleID": Bundle.main.bundleIdentifier ?? "unbundled",
            "AXTrusted": AXIsProcessTrusted(), "screenCapturePreflight": CGPreflightScreenCaptureAccess(),
            "screensHaveSeparateSpaces": NSScreen.screensHaveSeparateSpaces,
            "screens": screens(), "dockPreferencesReadOnly": preferences, "nativeDock": dock(options),
            "cgWindowsWhitelist": ownCGWindows(options.ownerPIDs), "mutatedSystemPreferences": false
        ]
        if let pid = options.windowPID { result["AXWindows"] = windows(pid) }
        return result
    }

    static func write(_ snapshot: [String: Any], to url: URL?) throws {
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else { FileHandle.standardOutput.write(data + Data([10])) }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--include-visible-menus" { options.includeVisibleMenus = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw NSError(domain: "NativeParityProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少参数值：\(argument)"]) }
            let value = arguments[index + 1]
            switch argument {
            case "--dock-label": options.label = value
            case "--window-pid": options.windowPID = pid_t(value)
            case "--owner-pid": if let pid = pid_t(value) { options.ownerPIDs.insert(pid) }
            case "--output": options.output = URL(fileURLWithPath: value)
            case "--tag": options.tag = value
            default: throw NSError(domain: "NativeParityProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "未知参数：\(argument)"])
            }
            index += 2
        }
        return options
    }
}

#if !PARITY_FIXTURE
@main
struct NativeParityProbeMain {
    @MainActor static func main() {
        _ = NSApplication.shared
        do {
            let options = try NativeParityProbe.parse(Array(CommandLine.arguments.dropFirst()))
            let result = NativeParityProbe.snapshot(options)
            try NativeParityProbe.write(result, to: options.output)
            if let output = options.output {
                print("只读诊断已保存：\(output.path)；AXTrusted=\(AXIsProcessTrusted())；未执行 AX 动作或修改 Dock 偏好。")
            }
        } catch {
            FileHandle.standardError.write(Data("诊断失败：\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
#endif
