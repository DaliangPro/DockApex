import Foundation

/// 冷启动只转发一次；常驻期间的 reopen 可以继续切换分组。
/// 只合并紧邻的重复打开事件，不把代理的整个生命周期锁成“已经打开”。
struct GroupEntryActivationGate {
    private(set) var finishedLaunching = false
    private var lastForwardedAt: TimeInterval?

    mutating func didFinishLaunching(preparesOnly: Bool, now: TimeInterval) -> Bool {
        guard !finishedLaunching else { return false }
        finishedLaunching = true
        return !preparesOnly && shouldForward(now: now)
    }

    mutating func reopen(now: TimeInterval) -> Bool {
        // 冷启动的打开事件由 didFinishLaunching 统一处理；预热不会打开分组。
        guard finishedLaunching else { return false }
        return shouldForward(now: now)
    }

    private mutating func shouldForward(now: TimeInterval) -> Bool {
        if let lastForwardedAt, now - lastForwardedAt < 0.12 { return false }
        lastForwardedAt = now
        return true
    }
}

/// 预热绑定到主工具的某一次启动；PID 与启动时间必须同时匹配。
struct GroupEntryOwnerRequest {
    let processIdentifier: Int32
    let launchTime: TimeInterval

    init?(arguments: [String]) {
        func value(after flag: String) -> String? {
            let indices = arguments.indices.filter { arguments[$0] == flag }
            guard indices.count == 1, let index = indices.first, index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let rawPID = value(after: "--dockfolders-owner-pid"), let pid = Int32(rawPID), pid > 0,
              let rawTime = value(after: "--dockfolders-owner-start"), let time = Double(rawTime), time.isFinite, time > 0 else { return nil }
        processIdentifier = pid
        launchTime = time
    }
}
