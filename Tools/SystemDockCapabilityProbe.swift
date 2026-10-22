import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

/// 只读检查系统导出符号和 Dock 几何，不写偏好、不设置区域、不操作窗口。
@main
@MainActor
enum SystemDockCapabilityProbe {
    static func main() {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        ]
        let handles = paths.compactMap { dlopen($0, RTLD_LAZY | RTLD_LOCAL) }
        let names = [
            "SLSMainConnectionID", "CGSMainConnectionID", "SLSGetDockRectWithReason", "SLSGetDockRectWithOrientation",
            "SLSSetDockRectWithReason", "SLSSetDockRectWithOrientation", "CGSSetDockRect", "SLSSetDockRect",
            "CoreDockGetRect", "CoreDockGetContainerRect", "CoreDockGetMinimizeInPlace", "CoreDockGetEffect",
            "CoreDockMinimizeItemWithTitle", "CoreDockMinimizeItemsWithTitle", "CoreDockMinimizeItemWithTitleAsync",
            "CoreDockRestoreItem", "CoreDockSetMiniView", "CoreDockGetItemDockWindow", "CoreDockGetProcessWindow",
            "CoreDockPreventCommunicationWithDock", "SLSSetUniversalOwner", "SLSSetUniversalOwnerOfAllWindows"
        ]
        var symbols: [String: Any] = [:]
        for name in names {
            let pointer = handles.lazy.compactMap { dlsym($0, name) }.first
            symbols[name] = pointer.map { String(describing: $0) } ?? NSNull()
        }
        let screens = NSScreen.screens.map { screen -> [String: Any] in
            ["name": screen.localizedName, "frame": NSStringFromRect(screen.frame), "visibleFrame": NSStringFromRect(screen.visibleFrame),
             "displayID": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) ?? -1]
        }
        var result: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "symbols": symbols, "screens": screens,
                                     "mode": "只读：未调用 Set、最小化、恢复或 AX 动作", "screenCapturePermission": CGPreflightScreenCaptureAccess(), "accessibilityPermission": AXIsProcessTrusted()]
        typealias Connection = @convention(c) () -> Int32
        typealias GetDock = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32
        if let connectionPointer = handles.lazy.compactMap({ dlsym($0, "SLSMainConnectionID") }).first,
           let getPointer = handles.lazy.compactMap({ dlsym($0, "SLSGetDockRectWithReason") }).first {
            let connection = unsafeBitCast(connectionPointer, to: Connection.self)()
            var rect = CGRect.zero
            var reason: Int32 = -1
            let status = unsafeBitCast(getPointer, to: GetDock.self)(connection, &rect, &reason)
            result["dockRect"] = ["connection": connection, "status": status, "rect": NSStringFromRect(rect), "reason": reason]
        }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
