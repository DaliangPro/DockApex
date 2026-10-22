import AppKit
import ApplicationServices

/// 只读指定的运行应用；不打开应用、不执行 AX 动作、不切换桌面或激活窗口。
@main
@MainActor
struct AppWindowObserverChecks {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task {
            do { try await run(); exit(0) }
            catch { print("检查未通过：\(error.localizedDescription)"); exit(1) }
        }
        application.run()
    }

    private static func run() async throws {
        guard AXIsProcessTrusted() else { throw CheckError("当前进程没有辅助功能权限，没有请求或修改权限。") }
        var seconds: Double = 20
        var output = "Data/Diagnostics/app-window-observer-checks.json"
        var paths: [String] = []
        var index = 1
        let arguments = CommandLine.arguments
        while index < arguments.count {
            switch arguments[index] {
            case "--seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), (1...300).contains(value) else { throw CheckError("--seconds 需要 1 至 300 之间的秒数。") }
                seconds = value
            case "--output":
                index += 1
                guard index < arguments.count else { throw CheckError("--output 缺少 JSON 路径。") }
                output = arguments[index]
            default:
                guard !arguments[index].hasPrefix("--") else { throw CheckError("未知参数：\(arguments[index])") }
                paths.append(arguments[index])
            }
            index += 1
        }
        guard !paths.isEmpty else { throw CheckError("请指定一个或多个已经运行的 .app 路径。") }
        let references = paths.compactMap { AppReference(url: URL(fileURLWithPath: $0)) }
        let targets = references.filter { ShelfAppActions.running($0) != nil }
        guard !targets.isEmpty else { throw CheckError("指定目标均未运行；检查工具不会替您启动应用。") }
        let targetPaths = Set(targets.map(\.path))
        let service = AppWindowService.shared
        var changes = 0
        var trace: [[String: Any]] = []
        let started = Date()
        service.onChange = {
            changes += 1
            trace.append([
                "elapsedMilliseconds": Date().timeIntervalSince(started) * 1_000,
                "apps": service.cachedSnapshots.filter { targetPaths.contains($0.application.path) }.map { entry in
                    ["path": entry.application.path, "windowCount": entry.snapshot.windows.count,
                     "minimizedCount": entry.snapshot.windows.filter(\.isMinimized).count] as [String: Any]
                }
            ])
        }
        for target in targets {
            await withCheckedContinuation { continuation in service.refresh(target) { _ in continuation.resume() } }
        }
        let first = service.cachedSnapshots
        var registrationCounts: [Int] = []
        let reader = AppWindowReader()
        for target in targets {
            if let pid = ShelfAppActions.running(target)?.processIdentifier {
                _ = await reader.scan(processIdentifier: pid, applicationName: target.name)
                registrationCounts.append(await reader.observationRegistrationCount(processIdentifier: pid))
            }
        }
        await reader.retainProcesses([])
        let initialMilliseconds = Date().timeIntervalSince(started) * 1_000
        let beforeChanges = changes
        let beforeWindows = service.cachedSnapshots.map(\.snapshot.windows)
        for target in targets {
            await withCheckedContinuation { continuation in service.refresh(target) { _ in continuation.resume() } }
        }
        let afterWindows = service.cachedSnapshots.map(\.snapshot.windows)
        let noFalseChanges = beforeWindows != afterWindows || beforeChanges == changes
        let initialEvents = service.accessibilityEventsByNotification
        print("观察器已注册，开始只读等待真实窗口通知 \(Int(seconds)) 秒。")
        fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        let finalEntries = service.cachedSnapshots
        let eventKinds = service.accessibilityEventsByNotification.mapValues { $0 }.reduce(into: [String: Int]()) { result, pair in
            let count = pair.value - (initialEvents[pair.key] ?? 0)
            if count > 0 { result[pair.key] = count }
        }
        let changesBeforeStop = changes
        let traceBeforeStop = trace
        service.stopObserving()
        let afterStopChanges = changes
        let snapshotAfterStop = service.cachedSnapshots
        try await Task.sleep(for: .milliseconds(300))
        let stopStable = snapshotAfterStop.isEmpty && afterStopChanges == changes
        let report: [String: Any] = [
            "createdAtUTC": ISO8601DateFormatter().string(from: Date()),
            "observedSeconds": seconds, "targetPaths": targets.map(\.path),
            "skippedNotRunning": references.filter { !targetPaths.contains($0.path) }.map(\.path),
            "targetCount": targets.count, "initialCacheCount": first.count, "currentCacheCount": finalEntries.count,
            "initialWindowCounts": first.map { $0.snapshot.windows.count },
            "currentWindowCounts": finalEntries.map { $0.snapshot.windows.count },
            "currentMinimizedCount": finalEntries.flatMap(\.snapshot.windows).filter(\.isMinimized).count,
            "registrationCounts": registrationCounts, "initialCacheAndRegistrationMilliseconds": initialMilliseconds,
            "onChangeCountBeforeStop": changesBeforeStop, "events": eventKinds.values.reduce(0, +), "eventKinds": eventKinds,
            "cacheTrace": traceBeforeStop,
            "unchangedRefreshDoesNotNotify": noFalseChanges, "stopStable": stopStable,
            "performedAXActions": false, "changedSpaces": false, "activatedApplications": false,
            "readWindowTitlesLogged": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
        guard first.count == targets.count, noFalseChanges, stopStable else { throw CheckError("缓存或停止检查未通过，详见 JSON。") }
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
