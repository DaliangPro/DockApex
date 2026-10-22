import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// 只读指定受控进程的窗口图像是否可取得；图像只在内存，输出只有尺寸与编号。
@main
@MainActor
struct WindowCaptureReadinessChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard let text = CommandLine.arguments.dropFirst().first, let pid = pid_t(text), pid > 1 else {
            print("用法：WindowCaptureReadinessChecks 受控测试进程PID"); return
        }
        Task {
            do {
                guard CGPreflightScreenCaptureAccess() else { throw CheckError("屏幕录制权限预检为 false，没有请求权限。") }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20 }
                guard !windows.isEmpty else { throw CheckError("受控目标没有可捕获窗口，没有启动或操作目标。") }
                var values: [[String: Any]] = []
                for window in windows.prefix(4) {
                    let configuration = SCStreamConfiguration()
                    let scale = min(1, 1600 / max(window.frame.width, window.frame.height))
                    configuration.width = Int(window.frame.width * scale); configuration.height = Int(window.frame.height * scale)
                    configuration.showsCursor = false; configuration.capturesAudio = false
                    configuration.ignoreShadowsSingleWindow = true; configuration.shouldBeOpaque = false
                    let started = Date()
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                    values.append(["cgWindowID": window.windowID, "width": image.width, "height": image.height,
                        "elapsedMilliseconds": Date().timeIntervalSince(started) * 1000, "alphaInfo": image.alphaInfo.rawValue])
                }
                let report: [String: Any] = ["screenCapturePreflight": true, "AXTrusted": AXIsProcessTrusted(), "pid": pid,
                    "capturedWindows": values, "imagesWritten": false, "performedAXActions": false, "requestedPermission": false]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(0)
            } catch { print("未通过：\(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
