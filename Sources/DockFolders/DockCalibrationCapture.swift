import AppKit
@preconcurrency import ScreenCaptureKit

/// 仅供本机几何校准：截取指定显示器底部一条区域保存为 PNG，然后退出，不启动应用栏。
/// 用法：DockFolders --capture-strip <显示器 UUID> <高度点数> <输出路径> [--exclude-dock | --only-bar]
enum DockCalibrationCapture {
    @MainActor
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--capture-strip"), arguments.count > index + 3,
              let height = Double(arguments[index + 2]), height > 0 else { return false }
        let uuid = arguments[index + 1], output = URL(fileURLWithPath: arguments[index + 3])
        guard let screen = NSScreen.screens.first(where: { DockDisplayDescriptor.uuid(for: $0) == uuid }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            FileHandle.standardError.write(Data("没有找到显示器 \(uuid)\n".utf8)); exit(2)
        }
        let displayID = number.uint32Value, scale = screen.backingScaleFactor, width = screen.frame.width
        let screenHeight = screen.frame.height
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        Task.detached {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CocoaError(.fileNoSuchFile) }
                // --exclude-dock：与补底使用同一组排除窗口，用于核对补底画面。
                let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
                // --only-bar：只留桌面层（壁纸）和本应用的窗口，用于说明文档配图，不带出其他 App 的窗口内容。
                let excluded = CommandLine.arguments.contains("--exclude-dock") ? content.windows.filter {
                    guard let app = $0.owningApplication else { return false }
                    return app.bundleIdentifier == "io.daliang.dockfolders" || (app.bundleIdentifier == "com.apple.dock" && $0.windowLayer >= dockLevel)
                } : CommandLine.arguments.contains("--only-bar") ? content.windows.filter {
                    $0.windowLayer >= 0 && $0.owningApplication?.bundleIdentifier != "io.daliang.dockfolders"
                } : []
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(x: 0, y: screenHeight - height, width: width, height: height)
                configuration.width = Int(width * scale); configuration.height = Int(height * scale)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: output)
                print("已保存：\(output.path)")
            } catch {
                FileHandle.standardError.write(Data("截取失败：\(error.localizedDescription)\n".utf8))
            }
            await MainActor.run { flag.done = true }
        }
        while !flag.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return true
    }
}
