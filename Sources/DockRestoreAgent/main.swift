import Darwin
import Foundation

// 一次性子进程：只观察所属主进程存活状态，退出或崩溃后条件恢复本会话修改的两个键。
// 与 NativeDockCoordinator.swift 一同编译；不注册 LaunchAgent、登录项或系统服务。
func runDockRestoreAgent() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 3, arguments[0] == "--restore-region", arguments[1] == "--data-directory" {
        let location = DockSystemRegionRecovery.Location(dataDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true))
        guard FileManager.default.fileExists(atPath: location.state.path) else {
            print("没有本工具的系统预留区会话，无需恢复。")
            return
        }
        let restored = try DockSystemRegionRecovery.withLock(at: location) {
            let session = try DockSystemRegionRecovery.load(location)
            guard session.phase == .inactive || !session.owner.isAlive else {
                throw DockSystemRegionError.message("主应用仍在运行，请先正常退出再恢复系统预留区。")
            }
            return try DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: DockSystemRegionAPI())
        }
        print(restored ? "已条件恢复系统 Dock 预留区。" : "系统预留区已恢复或后来已由系统更新，保留当前区域。")
        return
    }
    if arguments.count == 7, arguments[0] == "--watch-region", arguments[1] == "--data-directory",
       arguments[3] == "--session", let id = UUID(uuidString: arguments[4]), arguments[5] == "--owner",
       arguments[6].count < 4_096, let encoded = Data(base64Encoded: arguments[6]) {
        let owner = try JSONDecoder().decode(DockSystemRegionOwner.self, from: encoded)
        try DockSystemRegionRecovery.watch(dataDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true), expectedID: id, owner: owner)
        return
    }
    if arguments == ["--self-test-stop-guard"] {
        print(try DockStopGuardProtocol.selfTest())
        return
    }
    if arguments.count == 2, arguments[0] == "--guard-dock-stop" {
        try DockStopGuardHelper.run(encodedIdentity: arguments[1])
        return
    }
    if arguments == ["--self-test"] {
        print(try NativeDockRecovery.selfTest())
        return
    }
    if arguments.count == 3, arguments[0] == "--restore", arguments[1] == "--data-directory" {
        let location = NativeDockRecovery.Location(dataDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true))
        guard FileManager.default.fileExists(atPath: location.state.path) else {
            print("没有本工具的 Dock 隐藏会话，无需恢复。")
            return
        }
        let restored = try NativeDockRecovery.withLock(at: location) {
            let session = try NativeDockRecovery.load(location.state)
            return try NativeDockRecovery.restoreLocked(at: location, expectedID: session.id)
        }
        print(restored ? "已结束 Dock 隐藏会话，并按备份条件恢复；您后来更改的字段予以保留。" : "该会话已经结束，无需重复恢复。")
        return
    }
    guard arguments.count == 8 else { throw NativeDockError.message("恢复子进程参数不完整。") }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) { values[arguments[index]] = arguments[index + 1] }
    guard let pidText = values["--parent-pid"], let pid = Int32(pidText), pid > 1,
          let identity = values["--parent-identity"],
          let idText = values["--session"], let id = UUID(uuidString: idText),
          let backupPath = values["--backup"] else { throw NativeDockError.message("恢复子进程参数无效。") }
    let backup = URL(fileURLWithPath: backupPath).standardizedFileURL
    let location = try NativeDockRecovery.Location(backup: backup)
    let valid = try NativeDockRecovery.withLock(at: location) {
        try NativeDockRecovery.validateWatcherSession(at: location, backupURL: backup, id: id, pid: pid, identity: identity)
    }
    guard valid else { throw NativeDockError.message("恢复子进程没有匹配的活动会话。") }
    FileHandle.standardOutput.write(Data("READY\n".utf8))

    while true {
        var finished = false
        do {
            try NativeDockRecovery.withLock(at: location) {
                guard try NativeDockRecovery.validateWatcherSession(at: location, backupURL: backup, id: id, pid: pid, identity: identity) else {
                    finished = true
                    return
                }
                let session = try NativeDockRecovery.load(location.state)
                if !NativeDockRecovery.ownerIsAlive(session) {
                    try NativeDockRecovery.restoreLocked(at: location, expectedID: id)
                    finished = true
                }
            }
        } catch {
            // 瞬时同步失败时重试；只输出错误阶段，不记录用户输入或其他应用内容。
            let message = "\(ISO8601DateFormatter().string(from: Date())) 恢复重试：\(error.localizedDescription)\n"
            let log = location.directory.appendingPathComponent("watchdog-\(id.uuidString).log")
            if !FileManager.default.fileExists(atPath: log.path) {
                _ = FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: log) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(message.utf8))
                try? handle.close()
            }
        }
        if finished { return }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

do {
    try runDockRestoreAgent()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
