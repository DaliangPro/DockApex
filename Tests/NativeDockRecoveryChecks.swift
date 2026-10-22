import AppKit
import Foundation

/// 只在指定工作区目录建立会话 plist；不调用 Dock 偏好写入、进程恢复或 UI 动作。
@main
struct NativeDockRecoveryChecks {
    static func main() throws {
        print(try NativeDockRecovery.selfTest())
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/recovery-session-checks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let absent = NativeDockPreferenceValue(data: nil)
        let changes = try [
            NativeDockPreferenceChange(key: "autohide", original: .encoding(false), applied: .encoding(true)),
            NativeDockPreferenceChange(key: "autohide-delay", original: absent, applied: .encoding(3600.0))
        ]
        func fixture(version: Int, changes: [NativeDockPreferenceChange], attempted: [String]? = nil) -> NativeDockRecoverySession {
            NativeDockRecoverySession(version: version, id: UUID(), mainPID: getpid(),
                mainIdentity: NativeDockRecovery.processIdentity(getpid()) ?? "fixture", userID: getuid(), createdAt: Date(),
                changes: changes, phase: .active, attemptedKeys: attempted ?? changes.map(\.key), restoredKeys: [], preservedKeys: [])
        }
        var checks = 0
        func roundtrip(_ session: NativeDockRecoverySession, file: String, expectedValid: Bool) throws {
            let url = directory.appendingPathComponent(file + ".plist")
            try NativeDockRecovery.save(session, at: url)
            do {
                let loaded = try NativeDockRecovery.load(url)
                guard expectedValid, loaded.version == session.version, loaded.changes == session.changes else { throw CheckError("\(file) 未按预期拒绝或往返失败") }
            } catch {
                if expectedValid { throw error }
                if error is CheckError { throw error }
            }
            checks += 1
        }
        try roundtrip(fixture(version: 1, changes: changes), file: "v1-旧两键兼容", expectedValid: true)
        let animationChanges = try [
            NativeDockPreferenceChange(key: "mineffect", original: .encoding("scale"), applied: .encoding("genie")),
            NativeDockPreferenceChange(key: "genie-speed", original: absent, applied: .encoding(0.001))
        ]
        try roundtrip(fixture(version: 2, changes: changes + animationChanges), file: "v2-四键兼容", expectedValid: true)
        try roundtrip(fixture(version: 1, changes: changes + animationChanges), file: "v1-拒绝越界动画键", expectedValid: false)
        try roundtrip(fixture(version: 2, changes: changes), file: "v2-拒绝缺动画键", expectedValid: false)
        try roundtrip(fixture(version: 9, changes: changes), file: "拒绝未知版本", expectedValid: false)
        try roundtrip(fixture(version: 1, changes: changes + [changes[0]]), file: "拒绝重复键", expectedValid: false)
        let foreign = try NativeDockPreferenceChange(key: "persistent-apps", original: absent, applied: .encoding([]))
        try roundtrip(fixture(version: 2, changes: changes + animationChanges + [foreign]), file: "拒绝固定图标写入", expectedValid: false)
        try roundtrip(fixture(version: 1, changes: changes, attempted: ["mineffect"]), file: "拒绝写入意图越界", expectedValid: false)
        print("通过 \(checks) 项真实 plist 往返与非法会话拒绝检查。系统 Dock 偏好未修改。")
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
