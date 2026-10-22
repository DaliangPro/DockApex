import AppKit
import CoreGraphics
import Foundation

/// 只读系统工作区及真实 Dock 几何，不捕获屏幕或用户窗口内容。
@main
struct NativeHostGeometryProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        func rectangle(_ r: CGRect) -> [String: Double] {
            ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
        }
        let screens: [[String: Any]] = NSScreen.screens.map { s in
            let displayID = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return ["displayID": displayID, "name": s.localizedName,
                    "frame": rectangle(s.frame), "visibleFrame": rectangle(s.visibleFrame),
                    "nativeBottomInset": s.visibleFrame.minY - s.frame.minY,
                    // Muse 当前源码的定位公式：visible.minY + 43 - 24。
                    "museHUDOriginYFromCurrentSource": s.visibleFrame.minY + 19]
        }
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        let snapshot = try? DockAccessibility.currentSnapshot()
        let items: [[String: Any]] = (snapshot?.items ?? []).map {
            ["path": $0.appURL.path, "frame": rectangle($0.frame)]
        }
        let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        let finderWindows = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == finderPID && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .map { ["id": $0[kCGWindowNumber as String] ?? 0,
                    "title": $0[kCGWindowName as String] ?? "",
                    "frame": $0[kCGWindowBounds as String] ?? [:]] }
        let entryApplications: [[String: Any]] = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier?.hasPrefix("local.dockfolders.group.") == true }
            .map { ["pid": $0.processIdentifier, "path": $0.bundleURL?.path ?? "",
                    "activationPolicy": $0.activationPolicy.rawValue, "active": $0.isActive,
                    "launchTime": $0.launchDate?.timeIntervalSince1970 ?? 0] }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let preferenceKeys = ["orientation", "tilesize", "largesize", "magnification", "autohide", "autohide-delay", "show-process-indicators", "mineffect", "genie-speed"]
        var preferences: [String: Any] = [:]
        for key in preferenceKeys {
            preferences[key] = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) ?? NSNull()
        }
        let value: [String: Any] = ["timeUTC": ISO8601DateFormatter().string(from: Date()),
            "screens": screens, "dockPID": dock?.processIdentifier ?? 0, "dockItems": items,
            "preferences": preferences, "accessibility": AXIsProcessTrusted(), "finderWindows": finderWindows,
            "entryApplications": entryApplications]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        } else { FileHandle.standardOutput.write(data + Data([10])) }
    }
}
