import AppKit
import ApplicationServices

/// 仅检查已有应用的读取生命周期；不启动应用、不改变窗口、不输出窗口标题。
@main
@MainActor
enum AppWindowLifecycleChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            do { try await run(); exit(0) }
            catch { print("检查失败：\(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }

    private static func run() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw CheckError(message) }
            assertions += 1
        }
        let applications = ShelfRunningApplications.shared
        guard let target = applications.regularReferences.first else { throw CheckError("当前没有可供只读检查的运行应用。") }
        let service = AppWindowService.shared
        var cancelled: [AppWindowSnapshot] = []
        service.refresh(target) { cancelled.append($0) }
        service.refresh(target) { cancelled.append($0) }
        service.stopObserving()
        try check(cancelled.count == 2, "同一进行中读取的两个等待方，在停止时应各收到一次结果。")
        try check(cancelled.allSatisfy { !$0.isComplete && $0.windows.isEmpty && $0.errorDescription != nil }, "取消结果不能冒充完整窗口列表。")
        var reopened: [AppWindowSnapshot] = []
        service.refresh(target) { reopened.append($0) }
        let deadline = Date().addingTimeInterval(5)
        while reopened.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(reopened.count == 1, "停止后立即重新读取应完成，旧任务不能清空新请求。")
        try check(cancelled.count == 2, "旧请求不能回调第二次。")
        let observedWindows = reopened.first?.windows.count ?? 0
        service.stopObserving()
        try await Task.sleep(for: .milliseconds(300))
        try check(service.cachedSnapshots.isEmpty, "停止后迟到的 AX 结果不能重新填充缓存。")
        let missing = AppReference(path: "/not-installed/DockLifecycleFixture.app", name: "不存在的夹具", bundleIdentifier: nil)
        var unavailable: AppWindowSnapshot?
        service.refresh(missing) { unavailable = $0 }
        try check(unavailable?.processIdentifier == 0 && unavailable?.windows.isEmpty == true, "未运行应用仍应完成回调。")
        let menu = ShelfAppActions.applicationMenu(target)
        try check(!menu.items.contains { $0.title == "应用原生 Dock 菜单…" }, "共同应用菜单不能保留尚未验证且会留下系统菜单 tracking 的专属菜单入口。")
        let report: [String: Any] = ["checksPassed": assertions, "accessibilityTrusted": AXIsProcessTrusted(),
                                   "cancelledCallbacks": cancelled.count, "reopenedCallbacks": reopened.count,
                                   "observedWindowCount": observedWindows, "performedUIActions": false,
                                   "mutatedSystemSettings": false, "loggedWindowTitles": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = CommandLine.arguments.dropFirst().first { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
