import AppKit
import ApplicationServices

/// 单独编译的受控双窗口夹具。不访问用户文档，不修改 Dock 设置。
@main
@MainActor
struct WindowServiceChecks {
    private static var fixtureDelegate: FixtureDelegate?

    static func main() {
        let arguments = CommandLine.arguments
        let application = NSApplication.shared
        if arguments.contains("--fixture") {
            application.setActivationPolicy(.regular)
            let delegate = FixtureDelegate(minimized: arguments.contains("--minimized"))
            fixtureDelegate = delegate
            application.delegate = delegate
            application.run()
            return
        }
        guard let index = arguments.firstIndex(where: { $0 == "--inspect" || $0 == "--exercise" || $0 == "--responsiveness" }),
              arguments.indices.contains(index + 1), let pid = Int32(arguments[index + 1]) else {
            print("用法：WindowServiceChecks --fixture [--minimized] | --inspect PID | --exercise PID | --responsiveness PID")
            return
        }
        application.setActivationPolicy(.prohibited)
        let exercise = arguments[index] == "--exercise"
        let responsiveness = arguments[index] == "--responsiveness"
        Task {
            let reader = AppWindowReader()
            var pulses = 0
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    pulses += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            let start = Date()
            let initial = await reader.scan(processIdentifier: pid, applicationName: "窗口测试夹具")
            let elapsed = Date().timeIntervalSince(start)
            heartbeat.cancel()
            output(initial, label: "initial")
            if responsiveness {
                print("AX耗时=\(Int(elapsed * 1000))ms，主线程心跳=\(pulses)")
                guard initial.hasAccessibilityPermission, initial.errorDescription != nil, elapsed < 1.5, pulses >= 3 else {
                    print("未通过：请使用已 SIGSTOP 的受控夹具测试超时与主线程响应。"); exit(7)
                }
                print("通过：无响应进程读取有界超时，等待期间主线程继续响应。")
                exit(0)
            }
            guard exercise else { exit(initial.hasAccessibilityPermission ? 0 : 2) }
            guard initial.hasAccessibilityPermission else { print("未验证：检查进程缺少辅助功能权限。"); exit(2) }
            guard initial.windows.count == 2, initial.windows.allSatisfy(\.isMinimized) else {
                print("未验证：需要 --fixture --minimized 创建的两个已最小化窗口。"); exit(3)
            }
            let restored = await reader.restoreIfAllMinimized(processIdentifier: pid, applicationName: "窗口测试夹具")
            let afterFirst = await reader.scan(processIdentifier: pid, applicationName: "窗口测试夹具")
            output(afterFirst, label: "restored-one")
            guard restored.succeeded, afterFirst.windows.filter({ !$0.isMinimized }).count == 1,
                  let remaining = afterFirst.windows.first(where: \.isMinimized) else {
                print("失败：全部最小化时未恢复恰好一个窗口。"); exit(4)
            }
            let raised = await reader.raise(windowID: remaining.id, processIdentifier: pid)
            let afterSecond = await reader.scan(processIdentifier: pid, applicationName: "窗口测试夹具")
            output(afterSecond, label: "selected-second")
            guard raised.succeeded, afterSecond.windows.allSatisfy({ !$0.isMinimized }) else {
                print("失败：选择另一个窗口后未恢复该窗口。"); exit(5)
            }
            let noRestore = await reader.restoreIfAllMinimized(processIdentifier: pid, applicationName: "窗口测试夹具")
            let stale = await reader.raise(windowID: "不存在的窗口", processIdentifier: pid)
            guard !noRestore.succeeded, !stale.succeeded, stale.errorDescription != nil else {
                print("失败：可见窗口或陈旧句柄保护不符合预期。"); exit(6)
            }
            print("通过：双窗口读取、只恢复一个、指定恢复另一窗口、可见窗口不重复恢复、陈旧句柄拒绝。")
            exit(0)
        }
        application.run()
    }

    private static func output(_ snapshot: AppWindowSnapshot, label: String) {
        let value: [String: Any] = [
            "step": label,
            "pid": snapshot.processIdentifier,
            "trusted": snapshot.hasAccessibilityPermission,
            "error": snapshot.errorDescription ?? "",
            "windows": snapshot.windows.map { ["id": $0.id, "title": $0.title, "minimized": $0.isMinimized, "main": $0.isMain, "focused": $0.isFocused,
                "cgWindowID": $0.cgWindowID.map { Int($0) } ?? 0, "quartzFrame": $0.quartzFrame.map { NSStringFromRect($0) } ?? ""] as [String: Any] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        fflush(stdout)
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private let minimized: Bool
    private var windows: [NSWindow] = []

    init(minimized: Bool) { self.minimized = minimized }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 1...2 {
            let window = NSWindow(contentRect: NSRect(x: 300 + index * 100, y: 400 + index * 50, width: 360, height: 220), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "DockFolders 测试窗口 \(index)"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "可控测试窗口 \(index)，没有用户数据。")
            label.frame = NSRect(x: 20, y: 80, width: 320, height: 30)
            window.contentView?.addSubview(label)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if minimized { for window in windows { window.miniaturize(nil) } }
            try? await Task.sleep(for: .milliseconds(700))
            print("夹具就绪 PID=\(ProcessInfo.processInfo.processIdentifier)，窗口=\(windows.count)，最小化=\(minimized)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
