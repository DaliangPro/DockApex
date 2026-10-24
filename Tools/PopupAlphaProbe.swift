import AppKit
import CoreGraphics
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

private struct ProbeSession: Decodable {
    let mainPID: Int32
    let mainIdentity: String
    let userID: UInt32
}

private enum ProbeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// 只读取当前 DockFolders 自有弹出面板的 alpha 数值；不控制 UI，不保存图像。
@main
struct PopupAlphaProbe {
    @MainActor static func main() async {
        // 命令行中先建立只读 AppKit / WindowServer 连接；不创建、激活或显示窗口。
        _ = NSApplication.shared
        var dataDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("Data", isDirectory: true)
        var requestedPID: Int32?
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pid":
                index += 1
                if index < arguments.count { requestedPID = Int32(arguments[index]) }
            case "--data-directory":
                index += 1
                if index < arguments.count { dataDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true) }
            case "--help", "-h":
                print("用法：PopupAlphaProbe [--pid 主应用PID] [--data-directory 数据目录]。只捕获已打开的本应用分组/文件夹窗口，不保存图像。")
                return
            default:
                print("未知参数：\(arguments[index])")
                exit(2)
            }
            index += 1
        }

        var result: [String: Any] = ["schemaVersion": 1, "captured": false,
                                      "screenCapturePreflight": CGPreflightScreenCaptureAccess(),
                                      "timeUTC": ISO8601DateFormatter().string(from: Date())]
        var exitCode: Int32 = 0
        do {
            let sessionURL = dataDirectory.appendingPathComponent("NativeDockRecovery/current-session.plist")
            let session: ProbeSession
            if let requestedPID {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard requestedPID > 0, proc_pidinfo(requestedPID, PROC_PIDTBSDINFO, 0, &info, size) == size,
                      info.pbi_uid == getuid() else {
                    throw ProbeError.message("指定进程不是当前用户的有效进程；未捕获。")
                }
                session = ProbeSession(mainPID: requestedPID,
                    mainIdentity: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)", userID: getuid())
            } else {
                session = try PropertyListDecoder().decode(ProbeSession.self, from: Data(contentsOf: sessionURL))
            }
            let pid = session.mainPID
            guard pid == session.mainPID, session.userID == getuid(), matchesIdentity(session) else {
                throw ProbeError.message("主进程 PID、用户或开始时间与恢复会话不一致；未捕获。")
            }
            guard let application = NSRunningApplication(processIdentifier: pid),
                  application.bundleIdentifier == "io.daliang.dockfolders" else {
                throw ProbeError.message("目标不是当前 DockFolders 主应用；未捕获。")
            }
            result["ownerPID"] = pid
            guard CGPreflightScreenCaptureAccess() else {
                throw ProbeError.message("当前只读工具未取得屏幕捕捉授权；未请求权限，未捕获。")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let owned = content.windows.filter { $0.owningApplication?.processID == pid }
            let popups = owned.filter { window in
                guard window.isOnScreen, window.frame.width > 0, window.frame.height > 0, let title = window.title else { return false }
                return title.hasPrefix("DockApex · 分组：") || title.hasPrefix("DockApex · 文件夹：")
            }
            guard !popups.isEmpty else { throw ProbeError.message("当前没有可见的本应用分组或文件夹面板；未测。") }
            var captures: [[String: Any]] = []
            for window in popups {
                // 分享内容取得后再次核对身份；只使用精确 SCWindow 的独立窗口过滤器。
                guard matchesIdentity(session) else { throw ProbeError.message("捕获前主进程身份已改变；已停止。") }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                let captureRect = filter.contentRect
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(ceil(captureRect.width * scale)))
                configuration.height = max(1, Int(ceil(captureRect.height * scale)))
                configuration.showsCursor = false
                configuration.shouldBeOpaque = false
                configuration.ignoreShadowsSingleWindow = true
                let transparentBackground = CGColor(gray: 0, alpha: 0)
                configuration.backgroundColor = transparentBackground
                if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                withExtendedLifetime(transparentBackground) {}
                let sample = try alphaSamples(image)
                captures.append(["kind": window.title?.hasPrefix("DockApex · 分组：") == true ? "group" : "files",
                                 "windowID": window.windowID, "ownerPID": pid,
                                 "windowFramePoints": rect(window.frame), "filterContentRectPoints": rect(captureRect),
                                 "pointPixelScale": Double(scale), "configuredWidthPixels": configuration.width,
                                 "configuredHeightPixels": configuration.height, "imageWidthPixels": image.width,
                                 "imageHeightPixels": image.height, "sourceAlphaInfo": image.alphaInfo.rawValue,
                                 "shouldBeOpaque": false, "ignoreShadowsSingleWindow": true,
                                 "decodedBitmap": "RGBA8 premultipliedLast byteOrder32Big",
                                 "alphaSamples": sample,
                                 "transparentCornersObserved": sample.filter { ($0["corner"] as? String) != "center" }
                                    .allSatisfy { ($0["alpha"] as? Int ?? 255) <= 5 }])
            }
            result["captured"] = true
            result["captures"] = captures
            result["measurement"] = "独立自有窗口、关闭阴影并保留透明通道；角落按实际图像像素内缩 1、4、8 采样，中心为对照。"
        } catch {
            result["error"] = error.localizedDescription
            exitCode = 1
        }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let destination = dataDirectory.appendingPathComponent("Diagnostics/0.4-popup-alpha.json")
            try bytes.write(to: destination, options: .atomic)
            print(String(decoding: bytes, as: UTF8.self))
        } catch {
            print("alpha 诊断保存失败：\(error.localizedDescription)")
            exitCode = 2
        }
        exit(exitCode)
    }

    private static func matchesIdentity(_ session: ProbeSession) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard session.mainPID > 0, proc_pidinfo(session.mainPID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == session.userID else { return false }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)" == session.mainIdentity
    }

    private static func alphaSamples(_ image: CGImage) throws -> [[String: Any]] {
        let width = image.width, height = image.height
        guard width >= 18, height >= 18, width <= 16_384, height <= 16_384 else {
            throw ProbeError.message("面板图像尺寸不适合角落采样；未判定。")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { throw ProbeError.message("无法解码 RGBA8 透明通道。") }
        var samples: [[String: Any]] = []
        for inset in [1, 4, 8] {
            let points = [("row0-left", inset, inset), ("row0-right", width - 1 - inset, inset),
                          ("lastRow-left", inset, height - 1 - inset), ("lastRow-right", width - 1 - inset, height - 1 - inset)]
            for (name, x, y) in points {
                samples.append(["corner": name, "insetPixels": inset, "x": x, "y": y,
                                "alpha": Int(pixels[(y * width + x) * 4 + 3])])
            }
        }
        samples.append(["corner": "center", "x": width / 2, "y": height / 2,
                        "alpha": Int(pixels[((height / 2) * width + width / 2) * 4 + 3])])
        return samples
    }

    private static func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
}
