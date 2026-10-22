import AppKit
import Darwin

/// 纯索引和本机只读缓存检查；不启动应用、不投递工作区事件、不操作窗口。
@main
@MainActor
enum ShelfRunningApplicationsChecks {
    static func main() {
        do {
            var assertions = 0
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw CheckError(message) }
                assertions += 1
            }
            func identity(_ pid: pid_t, _ birth: UInt64) -> ShelfRunningProcessIdentity {
                ShelfRunningProcessIdentity(pid: pid, userID: getuid(), startedSeconds: birth, startedMicroseconds: 1)
            }
            let original = identity(100, 1), second = identity(200, 2), relaunched = identity(100, 3)
            let firstApp = AppReference(path: "/Applications/WeChat.app", name: "微信", bundleIdentifier: "com.tencent.xinWeChat")
            let secondApp = AppReference(path: "/Applications/WeChat Second.app", name: "微信二", bundleIdentifier: firstApp.bundleIdentifier)
            var index = ShelfRunningApplicationIndex()
            index.insert(ShelfRunningApplicationRecord(identity: original, reference: firstApp, aliases: ["/aliases/wechat.app"], isRegular: true))
            index.insert(ShelfRunningApplicationRecord(identity: second, reference: secondApp, aliases: [], isRegular: true))
            try check(index.candidates(path: firstApp.path).map(\.identity) == [original], "原始路径应准确匹配")
            try check(index.candidates(path: secondApp.path).map(\.identity) == [second], "双微信同 Bundle ID 不同路径应分开")
            try check(index.candidates(path: "/aliases/wechat.app").map(\.identity) == [original], "已建档符号链接别名应匹配")
            try check(index.candidates(path: "/unknown/WeChat.app").isEmpty, "未知路径不能按 Bundle ID 回退")
            index.insert(ShelfRunningApplicationRecord(identity: relaunched, reference: firstApp, aliases: [], isRegular: true))
            try check(index.candidates(path: firstApp.path).map(\.identity) == [relaunched], "PID 复用后替换出生身份")
            try check(index.candidates(path: "/aliases/wechat.app").isEmpty, "更新后不保留旧实例的别名")
            index.remove(pid: original.pid, matching: original)
            try check(index.records[relaunched.pid]?.identity == relaunched, "迟到退出不能移除新实例")
            let duplicate = identity(300, 4)
            index.insert(ShelfRunningApplicationRecord(identity: duplicate, reference: firstApp, aliases: [], isRegular: true))
            try check(index.candidates(path: firstApp.path).map(\.identity) == [duplicate, relaunched], "同路径多个实例选择较新者")
            index.remove(pid: duplicate.pid, matching: duplicate)
            try check(index.candidates(path: firstApp.path).map(\.identity) == [relaunched], "较新实例退出后原实例仍可用")
            index.remove(pid: relaunched.pid, matching: relaunched)
            try check(index.candidates(path: firstApp.path).isEmpty && index.candidates(path: secondApp.path).count == 1,
                      "移除不影响同 Bundle ID 的另一路径")
            try check(ShelfRunningProcessIdentity.capture(-1) == nil, "非法 PID 必须拒绝")
            try check(ShelfRunningProcessIdentity.capture(getpid())?.userID == getuid(), "真实内核身份应属于当前用户")

            let cache = ShelfRunningApplications.shared
            let initialScans = cache.initialSnapshotCount
            let metadataBuilds = cache.metadataBuildCount
            let references = cache.regularReferences
            try check(initialScans == 1, "初始化只取一次 NSWorkspace 清单")
            try check(!references.isEmpty, "本机应读取到实际普通应用")
            var validApplications = 0
            for reference in references {
                guard let running = cache.running(reference) else { continue }
                try check(cache.isCurrent(running), "运行对象需通过内核身份核验")
                try check(cache.reference(forPID: running.processIdentifier)?.path == reference.path, "PID 反查应保持准确路径")
                validApplications += 1
            }
            try check(validApplications > 0, "至少核验一个真实运行对象")
            if let first = references.first {
                for _ in 0..<200 { _ = cache.running(first) }
                let miss = AppReference(path: "/not-installed/never-scan.app", name: "不存在", bundleIdentifier: first.bundleIdentifier)
                for _ in 0..<200 { try check(cache.running(miss) == nil, "未命中查询不得借用同 Bundle ID 实例") }
            }
            try check(cache.initialSnapshotCount == initialScans, "重复命中或未命中均不触发全表扫描")
            try check(cache.metadataBuildCount == metadataBuilds, "查询期间不重复解析应用元数据")
            cache.start()
            try check(cache.initialSnapshotCount == initialScans, "重复 start 幂等")
            cache.stop()
            try check(cache.regularReferences.isEmpty, "stop 后清空普通应用快照")
            try check(references.allSatisfy { cache.running($0) == nil }, "stop 后不返回旧对象")
            cache.start()
            try check(cache.initialSnapshotCount == initialScans + 1 && !cache.regularReferences.isEmpty, "显式重新 start 能恢复清单")
            cache.stop()
            print("{\"assertionsPassed\":\(assertions),\"liveApplicationsVerified\":\(validApplications),\"initialWorkspaceScans\":\(initialScans),\"metadataBuilds\":\(metadataBuilds),\"queryCount\":400,\"performedUIActions\":false,\"mutatedSystemSettings\":false}")
        } catch {
            print("检查失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
