import CoreGraphics
import Foundation

/// 仅本机验收用：从命令行移动/点击/拖动鼠标或发送 Esc，然后退出，不启动应用栏。
/// 坐标使用 Quartz 全局坐标（主屏左上为原点）。用法：
///   DockFolders --mouse-move x y
///   DockFolders --mouse-click x y [left|right]
///   DockFolders --mouse-drag x1 y1 x2 y2 [seconds]
///   DockFolders --key-escape
enum DockAutomation {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--mouse-move"), arguments.count > index + 2,
           let x = Double(arguments[index + 1]), let y = Double(arguments[index + 2]) {
            let point = CGPoint(x: x, y: y)
            warp(point)
            move(point)
            print("moved \(x),\(y)")
            return true
        }
        if let index = arguments.firstIndex(of: "--mouse-click"), arguments.count > index + 2,
           let x = Double(arguments[index + 1]), let y = Double(arguments[index + 2]) {
            let point = CGPoint(x: x, y: y)
            let right = arguments.count > index + 3 && arguments[index + 3] == "right"
            warp(point)
            move(point)
            usleep(90_000)
            post(right ? .rightMouseDown : .leftMouseDown, at: point, button: right ? .right : .left)
            usleep(45_000)
            post(right ? .rightMouseUp : .leftMouseUp, at: point, button: right ? .right : .left)
            print("\(right ? "right" : "left") click \(x),\(y)")
            return true
        }
        if let index = arguments.firstIndex(of: "--mouse-drag"), arguments.count > index + 4,
           let x1 = Double(arguments[index + 1]), let y1 = Double(arguments[index + 2]),
           let x2 = Double(arguments[index + 3]), let y2 = Double(arguments[index + 4]) {
            let seconds = arguments.count > index + 5 ? (Double(arguments[index + 5]) ?? 0.6) : 0.6
            let hold = arguments.count > index + 6 ? (Double(arguments[index + 6]) ?? 0) : 0
            let start = CGPoint(x: x1, y: y1), end = CGPoint(x: x2, y: y2)
            warp(start)
            move(start)
            usleep(120_000)
            post(.leftMouseDown, at: start)
            let steps = 36
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                post(.leftMouseDragged, at: point)
                usleep(useconds_t(max(0, seconds) / Double(steps) * 1_000_000))
            }
            // 建组要求指针在目标中心慢下来（快速划过不算）；持续发送原地拖动事件，模拟手停在目标上。
            if hold > 0 {
                let deadline = Date().addingTimeInterval(hold)
                while Date() < deadline {
                    post(.leftMouseDragged, at: end)
                    usleep(30_000)
                }
            }
            post(.leftMouseUp, at: end)
            print("drag \(x1),\(y1) -> \(x2),\(y2) in \(seconds)s hold \(hold)s")
            return true
        }
        if arguments.contains("--key-escape") {
            key(53)
            print("escape")
            return true
        }
        if arguments.contains("--key-fullscreen") {
            key(3, flags: [.maskControl, .maskCommand])
            print("fullscreen key")
            return true
        }
        return false
    }

    private static func warp(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func move(_ point: CGPoint) {
        post(.mouseMoved, at: point)
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.post(tap: .cghidEventTap)
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
