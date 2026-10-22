import AppKit
import Foundation
import Darwin

@MainActor
final class DockIntegration {
    private let appID = "com.apple.dock" as CFString
    private let key = "persistent-apps" as CFString
    let backupsDirectory: URL
    private var latestURL: URL { backupsDirectory.appendingPathComponent("latest.plist") }

    init(backupsDirectory: URL) throws {
        self.backupsDirectory = backupsDirectory
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }

    func fixedItems() throws -> [[String: Any]] {
        try independentItems()
    }

    @discardableResult
    func replace(source: URL, target: URL, entry: URL, group: AppGroup, removing: [URL] = [], priorGroups: [AppGroup]) throws -> URL {
        let before = try fixedItems()
        let tile = DockLayout.newTile(url: entry, label: group.name, bundleIdentifier: Bundle(url: entry)?.bundleIdentifier)
        let after = DockLayout.replacing(tiles: before, source: source, target: target, replacement: tile, removing: removing)
        return try commit(before: before, after: after, priorGroups: priorGroups)
    }

    func refresh(entries: [(URL, String)], priorGroups: [AppGroup]) throws {
        let before = try fixedItems()
        let renamed = Dictionary(uniqueKeysWithValues: entries.map { (DockLayout.normalizedPath($0.0), $0) })
        let after = before.map { tile -> [String: Any] in
            guard let path = DockLayout.appURL(in: tile).map(DockLayout.normalizedPath),
                  let (_, name) = renamed[path] else { return tile }
            return Self.renamedTile(tile, label: name)
        }
        _ = try commit(before: before, after: after, priorGroups: priorGroups)
    }

    func remove(entries: [URL], restoring apps: [AppReference], priorGroups: [AppGroup]) throws {
        let before = try fixedItems()
        let removed = Set(entries.map(DockLayout.normalizedPath))
        let firstIndex = before.firstIndex { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath).map(removed.contains) ?? false } ?? before.count
        var after = before.filter { tile in
            guard let path = DockLayout.appURL(in: tile).map(DockLayout.normalizedPath) else { return true }
            return !removed.contains(path)
        }
        let current = Set(after.compactMap { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) })
        let inserted = apps.filter { !current.contains(DockLayout.normalizedPath($0.appURL)) }
            .map { DockLayout.newTile(url: $0.appURL, label: $0.name, bundleIdentifier: $0.bundleIdentifier) }
        after.insert(contentsOf: inserted, at: min(firstIndex, after.count))
        _ = try commit(before: before, after: after, priorGroups: priorGroups)
    }

    func latestUndoGroups() throws -> [AppGroup]? {
        guard let data = try? Data(contentsOf: latestURL),
              let backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              backup["undone"] as? Bool != true,
              backup["failed"] as? Bool != true,
              let groupsData = backup["groupsBefore"] as? Data else { return nil }
        return try JSONDecoder().decode([AppGroup].self, from: groupsData)
    }

    func restoreLatest(force: Bool = false, preparation: () throws -> Void = {}) throws {
        let data = try Data(contentsOf: latestURL)
        guard var backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              backup["undone"] as? Bool != true,
              let before = backup["before"] as? [[String: Any]],
              let after = backup["after"] as? [[String: Any]] else {
            throw DockFoldersError.message("没有可恢复的 Dock 备份。")
        }
        let current = try fixedItems()
        guard force || DockLayout.identities(current) == DockLayout.identities(after) else {
            throw DockFoldersError.message("分组后 Dock 布局已有其他改动；为保留这些改动，本次没有覆盖。备份位于项目 Data/Backups。")
        }
        try preparation()
        try replacePersistently(expected: current, desired: before)
        backup["undone"] = true
        let updated = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
        try updated.write(to: latestURL, options: .atomic)
    }

    /// 旧版 SIGTERM 提交可被 Dock 原样回写覆盖；只有整份 before 仍精确相等时才重放该笔。
    @discardableResult
    func repairUnpersistedCommit(expectedAfter: [[String: Any]]) throws -> Bool {
        guard let data = try? Data(contentsOf: latestURL),
              var backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              backup["undone"] as? Bool != true, backup["failed"] as? Bool != true,
              backup["nativePersistenceVerified"] as? Bool != true,
              let before = backup["before"] as? [[String: Any]], let after = backup["after"] as? [[String: Any]] else { return false }
        let current = try fixedItems()
        guard DockLayoutCommitRules.isExactRevertedTransaction(current: current, before: before, after: after,
                                                               expectedAfter: expectedAfter,
                nativePersistenceVerified: backup["nativePersistenceVerified"] as? Bool == true) else { return false }
        let persisted = try replacePersistently(expected: current, desired: after)
        backup["before"] = persisted.before
        backup["after"] = persisted.after
        backup["nativePersistenceVerified"] = true
        backup["repairedAt"] = Date()
        try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0).write(to: latestURL, options: .atomic)
        return true
    }

    /// 仅显式恢复指定的旧失败事务；不扫描历史备份，也不从旧 shelf 覆盖现有分组。
    @discardableResult
    func repairArchivedUnpersistedCommit(transactionURL: URL, expectedAfter: [[String: Any]]) throws -> Bool {
        let data = try Data(contentsOf: transactionURL)
        guard let backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              backup["undone"] as? Bool != true, backup["failed"] as? Bool != true,
              backup["nativePersistenceVerified"] as? Bool != true,
              let before = backup["before"] as? [[String: Any]], let after = backup["after"] as? [[String: Any]] else {
            throw DockFoldersError.message("指定归档不是可补回的未验证事务，未修改 Dock。")
        }
        let current = try fixedItems()
        let entries = backupsDirectory.deletingLastPathComponent().appendingPathComponent("Entries", isDirectory: true)
        guard let repaired = DockLayoutCommitRules.repairPlan(current: current, before: before, after: after,
            expectedAfter: expectedAfter, ownedEntriesDirectory: entries,
            nativePersistenceVerified: backup["nativePersistenceVerified"] as? Bool == true) else {
            throw DockFoldersError.message("原生 Dock 与归档旧布局存在额外改动，未补回或覆盖。只允许本工具分组的已知显示元数据变化。")
        }
        _ = try commit(before: current, after: repaired, priorGroups: [])
        return true
    }

    /// 一次事务更新整批分组；调用方必须以刚读取的原生布局为输入。
    @discardableResult
    func apply(before: [[String: Any]], after: [[String: Any]], priorGroups: [AppGroup]) throws -> URL? {
        guard !NSArray(array: before).isEqual(NSArray(array: after)) else { return nil }
        return try commit(before: before, after: after, priorGroups: priorGroups)
    }

    static func renamedTile(_ tile: [String: Any], label: String) -> [String: Any] {
        var tile = tile
        var data = tile["tile-data"] as? [String: Any] ?? [:]
        data["file-label"] = label
        tile["tile-data"] = data
        return tile
    }

    private func commit(before: [[String: Any]], after: [[String: Any]], priorGroups: [AppGroup]) throws -> URL {
        var backup: [String: Any] = ["before": before, "after": after, "createdAt": Date(),
                                   "transactionID": UUID().uuidString,
                                   "groupsBefore": try JSONEncoder().encode(priorGroups)]
        let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = backupsDirectory.appendingPathComponent("\(date)-Dock布局-\(UUID().uuidString.prefix(8)).plist")
        try data.write(to: url, options: .atomic)
        let current = try fixedItems()
        let entries = backupsDirectory.deletingLastPathComponent().appendingPathComponent("Entries", isDirectory: true)
        guard let rebased = DockLayoutCommitRules.rebaseOwnedMetadata(current: current, before: before, desired: after,
                                                                     ownedEntriesDirectory: entries) else {
            throw DockFoldersError.message("Dock 在操作期间发生额外变化，已保留原生改动并取消本次提交。")
        }
        let previousLatest = try? Data(contentsOf: latestURL)
        do {
            let persisted = try replacePersistently(expected: current, desired: rebased)
            backup["before"] = persisted.before
            backup["after"] = persisted.after
            backup["nativePersistenceVerified"] = true
            let verifiedData = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
            try verifiedData.write(to: url, options: .atomic)
            // 只有新 Dock 进程稳定读到目标身份顺序，事务才算成功。
            try verifiedData.write(to: latestURL, options: .atomic)
        } catch {
            if let previousLatest { try? previousLatest.write(to: latestURL, options: .atomic) }
            else {
                var failed = backup
                failed["failed"] = true
                if let data = try? PropertyListSerialization.data(fromPropertyList: failed, format: .binary, options: 0) {
                    try? data.write(to: latestURL, options: .atomic)
                }
            }
            throw error
        }
        return url
    }

    private func write(_ items: [[String: Any]]) throws {
        CFPreferencesSetAppValue(key, items as CFArray, appID)
        guard CFPreferencesAppSynchronize(appID),
              let actual = CFPreferencesCopyAppValue(key, appID) as? [[String: Any]],
              NSArray(array: actual).isEqual(NSArray(array: items)) else {
            throw DockFoldersError.message("Dock 布局写入核对失败。")
        }
    }

    /// 独立进程读取避免本进程 CFPreferences 缓存把“我刚写的值”误当成真实落地。
    private func independentItems() throws -> [[String: Any]] {
        let data = try DockBoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/defaults"),
                                              arguments: ["export", "com.apple.dock", "-"], timeout: 0.8)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = values["persistent-apps"] as? [[String: Any]] else {
            throw DockFoldersError.message("无法独立核对系统 Dock 固定项，未覆盖当前布局。")
        }
        return items
    }

    /// SIGTERM 会让 Dock 把旧内存布局写回。仅短暂停住已核验的本用户 Dock，写后强制重载。
    @discardableResult
    private func replacePersistently(expected: [[String: Any]], desired: [[String: Any]]) throws -> (before: [[String: Any]], after: [[String: Any]]) {
        guard let dock = DockLayoutProcess.current() else { throw DockFoldersError.message("没有找到可安全重载的当前用户 Dock。") }
        let stopGuard = try DockStopGuard.arm(processID: dock.pid)
        var stopped = false
        var killed = false
        var attemptedWrite = false
        var actualBefore = expected
        var written = desired
        defer {
            // 所有抛错路径都释放还活着的同一个 Dock，不能把桌面永久留在停止状态。
            if stopped, dock.isValid, dock.isStopped { _ = kill(dock.pid, SIGCONT) }
            stopGuard.cancel()
        }
        do {
            try stopGuard.beginPause()
            stopped = true
            let stopDeadline = Date().addingTimeInterval(0.15)
            while dock.isValid && !dock.isStopped && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.002) }
            guard dock.isValid, dock.isStopped, stopGuard.hasTimeRemaining else { throw DockFoldersError.message("Dock 未进入安全写入状态，本次没有写布局。") }
            let current = try independentItems()
            let entries = backupsDirectory.deletingLastPathComponent().appendingPathComponent("Entries", isDirectory: true)
            guard dock.isValid, dock.isStopped, stopGuard.hasTimeRemaining,
                  let rebased = DockLayoutCommitRules.rebaseOwnedMetadata(current: current, before: expected, desired: desired,
                                                                         ownedEntriesDirectory: entries) else {
                throw DockFoldersError.message("Dock 在提交前发生额外变化或暂停租约到期，已保留当前布局。")
            }
            actualBefore = current
            written = rebased
            attemptedWrite = true
            try write(written)
            guard dock.isValid, dock.isStopped, stopGuard.hasTimeRemaining,
                  NSArray(array: try independentItems()).isEqual(NSArray(array: written)) else {
                throw DockFoldersError.message("Dock 独立写入核对失败或安全暂停已结束。")
            }
            guard dock.isValid, dock.isStopped, stopGuard.hasTimeRemaining, kill(dock.pid, SIGKILL) == 0 else { throw DockFoldersError.message("无法安全重载已写入布局的 Dock。") }
            killed = true
            stopped = false
            stopGuard.cancel()
            let deadline = Date().addingTimeInterval(4)
            var verification = DockLayoutStableVerification()
            while Date() < deadline {
                let replacement = DockLayoutProcess.current()
                let isReplacement = replacement != nil && replacement != dock
                let matches = DockLayout.identities(try independentItems()) == DockLayout.identities(written)
                if verification.observe(isReplacement: isReplacement, identitiesMatch: matches) { return (actualBefore, written) }
                Thread.sleep(forTimeInterval: 0.12)
            }
            throw DockFoldersError.message("新 Dock 没有稳定读取到分组，未将本次操作报告为成功。")
        } catch {
            if attemptedWrite {
                let actual = try? independentItems()
                if !killed, stopped, dock.isValid, dock.isStopped, stopGuard.hasTimeRemaining,
                   let actual, DockLayoutCommitRules.canRollback(current: actual, written: written) {
                    try? write(actualBefore)
                } else if killed, let actual,
                          DockLayoutCommitRules.canRollback(current: actual, written: written),
                          let replacement = DockLayoutProcess.current(),
                          let rollbackGuard = try? DockStopGuard.arm(processID: replacement.pid) {
                    // 回滚也由独立助手暂停；任何元数据变化都不允许被旧值覆盖。
                    var rollbackOwnsPause = false
                    defer {
                        if rollbackOwnsPause, replacement.isValid, replacement.isStopped { _ = kill(replacement.pid, SIGCONT) }
                        rollbackGuard.cancel()
                    }
                    if (try? rollbackGuard.beginPause()) != nil {
                        rollbackOwnsPause = true
                        if replacement.isValid, replacement.isStopped, rollbackGuard.hasTimeRemaining,
                           let checked = try? independentItems(),
                           replacement.isStopped, rollbackGuard.hasTimeRemaining,
                           DockLayoutCommitRules.canRollback(current: checked, written: written) {
                            try? write(actualBefore)
                            if replacement.isValid, replacement.isStopped, rollbackGuard.hasTimeRemaining {
                                _ = kill(replacement.pid, SIGKILL)
                            }
                        }
                    }
                }
            }
            throw error
        }
    }
}

private struct DockLayoutProcess: Equatable {
    let pid: pid_t
    let identity: String
    var isValid: Bool { Self.capture(pid) == self }
    var isStopped: Bool {
        var info = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length && info.pbi_status == UInt32(SSTOP)
    }
    static func capture(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length,
              info.pbi_uid == getuid() else { return nil }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard count > 0, path == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" else { return nil }
        return Self(pid: pid, identity: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)")
    }
    static func current() -> Self? {
        // 不依赖主 RunLoop 派发 NSWorkspace 通知；重载期间直接查询当前用户进程。
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return nil }
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            if let process = capture(pid) { return process }
        }
        return nil
    }
}


enum DockLayoutCommitRules {
    static func rebaseOwnedMetadata(current: [[String: Any]], before: [[String: Any]], desired: [[String: Any]],
                                    ownedEntriesDirectory: URL) -> [[String: Any]]? {
        guard DockLayout.identities(current) == DockLayout.identities(before), current.count == before.count else { return nil }
        let directory = DockLayout.normalizedPath(ownedEntriesDirectory)
        var previousByID: [String: [String: Any]] = [:], currentByID: [String: [String: Any]] = [:]
        for (prior, actual) in zip(before, current) {
            if isOwnedEntry(prior, directory: directory) {
                guard equivalentOwnedTile(prior, actual) else { return nil }
            } else if !NSDictionary(dictionary: prior).isEqual(to: actual) { return nil }
            let id = DockLayout.identities([prior])[0]
            guard previousByID[id] == nil else { return nil }
            previousByID[id] = prior; currentByID[id] = actual
        }
        return desired.map { planned in
            let id = DockLayout.identities([planned])[0]
            guard isOwnedEntry(planned, directory: directory), let prior = previousByID[id], let actual = currentByID[id],
                  let priorData = prior["tile-data"] as? [String: Any], let actualData = actual["tile-data"] as? [String: Any],
                  var plannedData = planned["tile-data"] as? [String: Any] else { return planned }
            for field in ["file-label", "file-mod-date", "parent-mod-date"] {
                // 事务主动改名时保留计划值；否则继承系统刚更新的本工具元数据。
                let old = priorData[field], plan = plannedData[field]
                let equal = (old == nil && plan == nil) || (old as? NSObject)?.isEqual(plan) == true
                if equal { plannedData[field] = actualData[field] }
            }
            var result = planned; result["tile-data"] = plannedData
            return result
        }
    }

    static func canRollback(current: [[String: Any]], written: [[String: Any]]) -> Bool {
        NSArray(array: current).isEqual(NSArray(array: written))
    }

    static func repairPlan(current: [[String: Any]], before: [[String: Any]], after: [[String: Any]],
                           expectedAfter: [[String: Any]], ownedEntriesDirectory: URL,
                           nativePersistenceVerified: Bool = false) -> [[String: Any]]? {
        guard !nativePersistenceVerified, DockLayout.identities(before) != DockLayout.identities(after),
              DockLayout.identities(after) == DockLayout.identities(expectedAfter),
              DockLayout.identities(current) == DockLayout.identities(before), current.count == before.count else { return nil }
        let entries = DockLayout.normalizedPath(ownedEntriesDirectory)
        var currentByIdentity: [String: [String: Any]] = [:]
        for (prior, actual) in zip(before, current) {
            if isOwnedEntry(prior, directory: entries) {
                guard equivalentOwnedTile(prior, actual) else { return nil }
            } else if !NSDictionary(dictionary: prior).isEqual(to: actual) { return nil }
            let identity = DockLayout.identities([actual])[0]
            // 重复身份无法唯一合成，拒绝代猜。
            guard currentByIdentity[identity] == nil else { return nil }
            currentByIdentity[identity] = actual
        }
        let beforeIDs = Set(DockLayout.identities(before))
        let newlyInserted = after.filter { !beforeIDs.contains(DockLayout.identities([$0])[0]) }
        guard !newlyInserted.isEmpty, newlyInserted.allSatisfy({ isOwnedEntry($0, directory: entries) }) else { return nil }
        return after.map { tile in currentByIdentity[DockLayout.identities([tile])[0]] ?? tile }
    }

    private static func isOwnedEntry(_ tile: [String: Any], directory: String) -> Bool {
        guard let url = DockLayout.appURL(in: tile), url.pathExtension.lowercased() == "app",
              DockLayout.normalizedPath(url.deletingLastPathComponent()) == directory,
              let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return false }
        let identifier = (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        return identifier == "local.dockfolders.group." + id.uuidString.lowercased()
    }

    private static func equivalentOwnedTile(_ before: [String: Any], _ current: [String: Any]) -> Bool {
        var before = before, current = current
        guard var oldData = before["tile-data"] as? [String: Any], var newData = current["tile-data"] as? [String: Any] else { return false }
        for key in ["file-label", "file-mod-date", "parent-mod-date"] {
            let old = oldData[key], new = newData[key]
            if key == "file-label" {
                guard (old == nil || old is String) && (new == nil || new is String) else { return false }
            } else {
                guard (old == nil || old is NSNumber) && (new == nil || new is NSNumber) else { return false }
            }
            oldData.removeValue(forKey: key); newData.removeValue(forKey: key)
        }
        before["tile-data"] = oldData; current["tile-data"] = newData
        return NSDictionary(dictionary: before).isEqual(to: current)
    }

    static func isExactRevertedTransaction(current: [[String: Any]], before: [[String: Any]], after: [[String: Any]],
                                           expectedAfter: [[String: Any]], nativePersistenceVerified: Bool = false) -> Bool {
        !nativePersistenceVerified && DockLayout.identities(before) != DockLayout.identities(after)
            && DockLayout.identities(after) == DockLayout.identities(expectedAfter)
            && NSArray(array: current).isEqual(NSArray(array: before))
    }
}

struct DockLayoutStableVerification {
    private var consecutive = 0
    mutating func observe(isReplacement: Bool, identitiesMatch: Bool) -> Bool {
        consecutive = isReplacement && identitiesMatch ? consecutive + 1 : 0
        return consecutive >= 3
    }
}


/// 子进程只读导出带硬截止；不能在 Dock 停止期间无限等 pipe EOF 或 waitUntilExit。
@MainActor
enum DockBoundedProcess {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        guard timeout > 0, timeout <= 1 else { throw DockFoldersError.message("子进程超时上限无效。") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        try? output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DockFoldersError.message("无法建立带超时的偏好读取通道。")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let remaining = max(1, min(20, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let ready = poll(&event, 1, Int32(remaining))
            if ready < 0 && errno != EINTR { throw DockFoldersError.message("偏好读取通道中断。") }
            if ready > 0 {
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        result.append(contentsOf: buffer.prefix(count))
                        guard result.count <= 8 * 1024 * 1024 else { throw DockFoldersError.message("Dock 偏好导出超出安全读取范围。") }
                    } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR { throw DockFoldersError.message("Dock 偏好导出读取失败。") }
                }
            }
            if !process.isRunning {
                guard process.terminationStatus == 0 else { throw DockFoldersError.message("独立偏好读取子进程失败。") }
                return result
            }
        }
        // defer 只杀本次自己启动且仍在运行的子进程；不再同步等待其退出。
        throw DockFoldersError.message("独立偏好读取超时，已取消本次 Dock 修改。")
    }
}
