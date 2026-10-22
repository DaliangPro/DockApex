import AppKit
import ApplicationServices
import Darwin

/// 只读性能/生命周期检查。无响应场景只暂停本工具自己创建的无窗口子进程。
@main
@MainActor
struct NativeDockStatusChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--ax-fixture") { app.run(); return }
        Task {
            do { try await run(); exit(0) }
            catch { print("检查未通过：\(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        let resolverCheckCount = try resolverChecks()
        let valueCheckCount = try valueChecks()
        if arguments.contains("--resolver-checks-only") {
            print("{\"resolverChecksPassed\":\(resolverCheckCount),\"valueChecksPassed\":\(valueCheckCount),\"performedUIActions\":false,\"mutatedDockPreferences\":false}")
            return
        }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard AXIsProcessTrusted() else { throw CheckError("当前检查进程没有辅助功能权限；没有请求或改变权限。") }
        let count = min(60, max(3, Int(option("--samples") ?? "12") ?? 12))
        let fixturePath = URL(fileURLWithPath: option("--fixture-path") ?? "build/DockParityFixture.app").standardizedFileURL.resolvingSymlinksInPath().path
        var actualResolver = NativeDockStatusProcessResolver()
        guard let dockPID = actualResolver.resolve()?.pid else { throw CheckError("没有找到本用户的准确系统 Dock 进程。") }
        var values: [String: NativeDockItemStatus] = [:]
        var changedCount = 0
        var knownFixtureBadges = Set<String>()
        let source = NativeDockStatusSource { next in
            values = next
            changedCount += 1
            if let badge = next[fixturePath]?.badge { knownFixtureBadges.insert(badge) }
        }
        var samples: [NativeDockStatusSample] = []
        source.start()
        for _ in 0..<count {
            let next = try await sample(source, after: samples.last?.sequence ?? 0)
            guard next.outcome == .values, next.itemCount > 0 else { throw CheckError("系统 Dock 状态读取暂不可用（\(next.outcome.rawValue)）。") }
            samples.append(next)
        }
        let fixtureFound = values[fixturePath] != nil
        source.stop()
        let afterStopChanges = changedCount
        let afterStopSequence = source.lastSample?.sequence
        try await Task.sleep(for: .milliseconds(1_250))
        let stopStable = values.isEmpty && changedCount == afterStopChanges && source.lastSample?.sequence == afterStopSequence
        guard stopStable else { throw CheckError("stop 后仍有迟到状态回调或继续采样。") }

        var restartPassed = 0
        for _ in 0..<3 {
            let oldSequence = source.lastSample?.sequence ?? 0
            source.start()
            let next = try await sample(source, after: oldSequence)
            guard next.outcome == .values, next.itemCount > 0 else { throw CheckError("重新 start 后没有重新读取实际 Dock。") }
            source.stop()
            restartPassed += 1
        }

        var immediateCallbacks = 0
        let immediate = NativeDockStatusSource { _ in immediateCallbacks += 1 }
        immediate.start(); immediate.stop()
        try await Task.sleep(for: .milliseconds(350))
        let immediateCancel = immediate.lastSample == nil && immediateCallbacks == 0
        guard immediateCancel else { throw CheckError("立即取消仍产生样本或迟到回调。") }

        // 真正无响应的 AX 服务由自己的无窗口子进程提供，系统 Dock 和工作应用不暂停。
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--ax-fixture"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let childPID = child.processIdentifier
        defer {
            if child.isRunning { kill(childPID, SIGCONT); child.terminate() }
        }
        try await Task.sleep(for: .milliseconds(400))
        guard child.isRunning, kill(childPID, SIGSTOP) == 0 else { throw CheckError("无法暂停自己的 AX 检查夹具。") }
        var heartbeatCount = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { heartbeatCount += 1; try? await Task.sleep(for: .milliseconds(10)) }
        }
        let failure = NativeDockStatusSource(onChanged: { _ in }, processIdentifierProvider: { childPID })
        failure.start()
        let failureSample = try await sample(failure, after: 0)
        failure.stop()
        heartbeat.cancel()
        let boundedFailure = failureSample.outcome == .temporarilyUnavailable && failureSample.durationMilliseconds < 700 && heartbeatCount >= 3
        guard boundedFailure else { throw CheckError("无响应 AX 的超时或主线程响应检查不通过。") }

        var cancelledCallbacks = 0
        let cancelled = NativeDockStatusSource(onChanged: { _ in cancelledCallbacks += 1 }, processIdentifierProvider: { childPID })
        cancelled.start()
        try await Task.sleep(for: .milliseconds(20))
        cancelled.stop()
        try await Task.sleep(for: .milliseconds(500))
        let inFlightCancel = cancelled.lastSample == nil && cancelledCallbacks == 0
        guard inFlightCancel else { throw CheckError("在途取消后仍回传了过期状态。") }

        var injectedPID: pid_t? = dockPID
        var reconnectedValues: [String: NativeDockItemStatus] = [:]
        let reconnect = NativeDockStatusSource(onChanged: { reconnectedValues = $0 }, processIdentifierProvider: { injectedPID })
        reconnect.start()
        let first = try await sample(reconnect, after: 0)
        injectedPID = childPID
        let second = try await sample(reconnect, after: first.sequence)
        let changedPIDClears = second.processIdentifier == childPID && second.outcome == .temporarilyUnavailable && reconnectedValues.isEmpty
        injectedPID = dockPID
        let third = try await sample(reconnect, after: second.sequence)
        let reconnected = third.processIdentifier == dockPID && third.outcome == .values && !reconnectedValues.isEmpty
        reconnect.stop()
        guard changedPIDClears && reconnected else { throw CheckError("PID 变化后的清空或重新连接未通过。") }
        kill(childPID, SIGCONT); child.terminate()
        try await Task.sleep(for: .milliseconds(150))
        if child.isRunning { kill(childPID, SIGKILL); try await Task.sleep(for: .milliseconds(100)) }
        let childCleaned = !child.isRunning
        guard childCleaned else { throw CheckError("检查夹具未结束。") }

        let milliseconds = samples.map(\.durationMilliseconds).sorted()
        let mean = milliseconds.reduce(0, +) / Double(milliseconds.count)
        let report: [String: Any] = [
            "createdAtUTC": ISO8601DateFormatter().string(from: Date()),
            "resolverChecksPassed": resolverCheckCount,
            "valueChecksPassed": valueCheckCount,
            "trusted": AXIsProcessTrusted(), "dockPID": dockPID,
            "sampleCount": samples.count,
            "durationMilliseconds": ["min": milliseconds[0], "median": milliseconds[milliseconds.count / 2], "mean": mean, "p95": milliseconds[min(milliseconds.count - 1, Int(ceil(Double(milliseconds.count) * 0.95)) - 1)], "max": milliseconds.last!],
            "itemCounts": samples.map(\.itemCount),
            "fixtureFound": fixtureFound, "fixtureObservedBadges": knownFixtureBadges.sorted(),
            "checks": ["stopStable": stopStable, "restartCount": restartPassed, "immediateCancel": immediateCancel, "inFlightCancel": inFlightCancel, "boundedAXFailure": boundedFailure, "changedPIDClears": changedPIDClears, "reconnectToActualDock": reconnected, "fixtureChildCleaned": childCleaned],
            "unresponsiveAXMilliseconds": failureSample.durationMilliseconds,
            "mainActorHeartbeatCount": heartbeatCount,
            "performedUIActions": false, "mutatedDockPreferences": false,
            "failureFixture": "仅本工具创建的无窗口子进程；PID变化由测试注入，未重启系统Dock",
            "permissionRevocationTested": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = option("--output") { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        print(String(data: data, encoding: .utf8)!)
    }

    private static func resolverChecks() throws -> Int {
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckError("进程身份检查失败：\(message)") }
            passed += 1
        }
        let first = NativeDockStatusProcess(pid: 10, startedSeconds: 100, startedMicroseconds: 1)
        let reused = NativeDockStatusProcess(pid: 10, startedSeconds: 101, startedMicroseconds: 1)
        let restarted = NativeDockStatusProcess(pid: 20, startedSeconds: 102, startedMicroseconds: 2)
        var identities: [pid_t: NativeDockStatusProcess] = [10: first]
        var pids: [pid_t] = [9, 10, 11]
        var listCalls = 0, captureCalls = 0
        var resolver = NativeDockStatusProcessResolver(processList: { listCalls += 1; return pids }, capture: { pid in
            captureCalls += 1; return identities[pid]
        })
        try check(resolver.resolve() == first && listCalls == 1, "首次发现")
        captureCalls = 0
        for _ in 0..<20 { try check(resolver.resolve() == first, "缓存身份稳定") }
        try check(listCalls == 1 && captureCalls == 20, "缓存命中不遍历进程列表")
        identities[10] = reused
        try check(resolver.resolve() == reused && listCalls == 2, "同 PID 开始时间改变时重新发现")
        identities[10] = nil; identities[20] = restarted; pids = [9, 20]
        try check(resolver.resolve() == restarted && listCalls == 3, "Dock 换 PID 后重新发现")
        identities[20] = nil; pids = [9]
        try check(resolver.resolve() == nil && listCalls == 4, "退出后不返回旧 PID")
        identities[20] = restarted; pids = [20]
        try check(resolver.resolve() == restarted && listCalls == 5, "暂时缺失后可重新连接")
        try check(NativeDockStatusProcess.currentUserPIDs().contains(getpid()), "仅本用户 PID 枚举包含当前进程")
        try check(NativeDockStatusProcess.capture(getpid(), requiresDockPath: false)?.pid == getpid(), "实际 PID 和开始时间可读取")
        try check(NativeDockStatusProcess.capture(getpid()) == nil, "检查程序不能冒充系统 Dock")
        try check(NativeDockStatusProcess.capture(-1, requiresDockPath: false) == nil, "拒绝非法 PID")
        return passed
    }

    private static func valueChecks() throws -> Int {
        var passed = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw CheckError("角标状态检查失败：\(message)") }
            passed += 1
        }
        func failure(_ code: AXError) -> AXValue {
            var error = code
            return AXValueCreate(.axError, &error)!
        }
        let absent = failure(.noValue)
        let unsupported = failure(.attributeUnsupported)
        try check(NativeDockStatusValue.decode(label: " 23\n", progress: absent) == NativeDockItemStatus(badge: "23", progress: nil), "数字角标保留文字")
        try check(NativeDockStatusValue.decode(label: "●", progress: unsupported)?.badge == "●", "非数字角标不能丢失")
        try check(NativeDockStatusValue.decode(label: "  ", progress: absent)?.badge == nil, "空文字确认清除角标")
        try check(NativeDockStatusValue.decode(label: absent, progress: unsupported) == NativeDockItemStatus(badge: nil, progress: nil), "无值与不支持属于已知空状态")
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure] {
            try check(NativeDockStatusValue.decode(label: failure(error), progress: absent) == nil, "读取失败必须保留未知状态")
            try check(NativeDockStatusValue.decode(label: "23", progress: failure(error)) == nil, "部分属性失败不应发布完整快照")
        }
        try check(NativeDockStatusValue.decode(label: "7", progress: NSNumber(value: 0.4))?.progress == 0.4, "进度保留原始有限值")
        try check(NativeDockStatusValue.decode(label: "7", progress: NSNumber(value: Double.nan))?.progress == nil, "无效进度不传播")
        return passed
    }

    private static func sample(_ source: NativeDockStatusSource, after sequence: Int) async throws -> NativeDockStatusSample {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if let value = source.lastSample, value.sequence > sequence { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        source.stop()
        throw CheckError("等待只读样本超时。")
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
