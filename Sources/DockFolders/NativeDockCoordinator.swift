import AppKit
import CoreFoundation
import Darwin
import Foundation

enum NativeDockError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// nil 表示原来没有这个偏好项，恢复时必须删除键，不能擅自补默认值。
struct NativeDockPreferenceValue: Codable, Equatable, Sendable {
    let data: Data?

    /// 数组和字典的二进制编码可能因键顺序不同而不同；按解码后的属性列表内容比较。
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.data == rhs.data { return true }
        guard let left = try? lhs.decoded(), let right = try? rhs.decoded() else { return false }
        // Dock 载入固定项后会补写 GUID 等内部字段；固定项只按类型与应用身份比较。
        if let a = left as? [[String: Any]], let b = right as? [[String: Any]] { return tileIdentity(a) == tileIdentity(b) }
        return (left as AnyObject).isEqual(right)
    }

    private static func tileIdentity(_ tiles: [[String: Any]]) -> [String] {
        tiles.map { tile in
            let data = tile["tile-data"] as? [String: Any]
            let url = (data?["file-data"] as? [String: Any])?["_CFURLString"] as? String
            return [tile["tile-type"] as? String ?? "", data?["bundle-identifier"] as? String ?? "", url ?? ""].joined(separator: "|")
        }
    }

    static func encoding(_ value: Any?) throws -> Self {
        guard let value else { return Self(data: nil) }
        return Self(data: try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0))
    }

    func decoded() throws -> Any? {
        guard let data else { return nil }
        guard let wrapper = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = wrapper["value"] else {
            throw NativeDockError.message("Dock 偏好备份格式不正确。")
        }
        return value
    }
}

struct NativeDockPreferenceChange: Codable, Equatable, Sendable {
    let key: String
    let original: NativeDockPreferenceValue
    let applied: NativeDockPreferenceValue
}

struct NativeDockRecoverySession: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, active, restoring, inactive }
    let version: Int
    let id: UUID
    let mainPID: Int32
    let mainIdentity: String
    let userID: UInt32
    let createdAt: Date
    let changes: [NativeDockPreferenceChange]
    var phase: Phase
    var attemptedKeys: [String]
    var restoredKeys: [String]
    var preservedKeys: [String]
    var finishedAt: Date?
}

/// 主应用和一次性恢复子进程共用同一恢复逻辑；不会安装 LaunchAgent 或后台服务。
enum NativeDockRecovery {
    static let domain = "com.apple.dock"
    static let legacyKeys = Set(["autohide", "autohide-delay"])
    static let animationKeys = Set(["mineffect", "genie-speed"])
    /// 影子模式：系统 Dock 保持显示负责占位与最小化终点，内容精简并由应用栏覆盖。
    static let shadowKeys = Set(["autohide", "persistent-apps", "persistent-others", "show-recents", "magnification", "tilesize", "orientation"])
    static let allowedKeys = legacyKeys.union(animationKeys).union(shadowKeys)
    /// 经典模式（会话 v4）下由本应用运行中反复调整的键：隐藏系统 Dock 的图标尺寸，用来让最小化终点对准应用栏。
    /// 进入时不写；第一次调整前登记为已尝试。恢复时只要与原值不同就写回原值，不按“是否仍等于写入值”判断。
    static let managedKeys = Set(["tilesize"])

    static func isManaged(_ key: String, in session: NativeDockRecoverySession) -> Bool {
        session.version == 4 && managedKeys.contains(key)
    }

    struct Location: Sendable {
        let directory: URL
        var state: URL { directory.appendingPathComponent("current-session.plist") }
        var lock: URL { directory.appendingPathComponent("session.lock") }
        var backups: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
        func backup(_ id: UUID) -> URL { backups.appendingPathComponent("\(id.uuidString).plist") }

        init(dataDirectory: URL) {
            directory = dataDirectory.appendingPathComponent("NativeDockRecovery", isDirectory: true)
        }

        init(backup: URL) throws {
            guard backup.isFileURL, backup.deletingLastPathComponent().lastPathComponent == "Backups",
                  backup.pathExtension == "plist" else {
                throw NativeDockError.message("恢复备份路径不正确。")
            }
            directory = backup.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        }
    }

    static func processIdentity(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    static func ownerIsAlive(_ session: NativeDockRecoverySession) -> Bool {
        session.userID == getuid() && processIdentity(session.mainPID) == session.mainIdentity
    }

    static func withLock<T>(at location: Location, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: location.backups, withIntermediateDirectories: true)
        let descriptor = open(location.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NativeDockError.message("无法建立 Dock 恢复锁。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw NativeDockError.message("无法锁定 Dock 恢复会话。") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func load(_ url: URL) throws -> NativeDockRecoverySession {
        let value = try PropertyListDecoder().decode(NativeDockRecoverySession.self, from: Data(contentsOf: url))
        let keys = Set(value.changes.map(\.key))
        let validVersion = (value.version == 1 && keys == legacyKeys) || (value.version == 2 && keys == legacyKeys.union(animationKeys))
            || (value.version == 3 && keys == shadowKeys) || (value.version == 4 && keys == legacyKeys.union(managedKeys))
        guard validVersion, value.userID == getuid(), value.changes.count == keys.count,
              Set(value.attemptedKeys).isSubset(of: keys), Set(value.restoredKeys).isSubset(of: keys),
              Set(value.preservedKeys).isSubset(of: keys) else {
            throw NativeDockError.message("Dock 恢复会话校验失败，未修改系统设置。")
        }
        return value
    }

    static func save(_ session: NativeDockRecoverySession, at url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func synchronize() throws {
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NativeDockError.message("无法同步系统 Dock 偏好。")
        }
    }

    static func read(_ key: String) throws -> NativeDockPreferenceValue {
        guard allowedKeys.contains(key) else { throw NativeDockError.message("拒绝读取不属于本次恢复范围的偏好。") }
        return try .encoding(independentPreferences()[key])
    }

    /// 读取真实偏好服务的独立导出，避免把本进程刚写入的缓存误报为生效。
    static func independentPreferences() throws -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["export", domain, "-"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        try process.run()
        try? output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NativeDockError.message("无法建立独立 Dock 偏好读取通道。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&event, 1, 10)
            if ready < 0, errno != EINTR { throw NativeDockError.message("独立 Dock 偏好通道中断。") }
            if ready > 0 {
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        data.append(contentsOf: buffer.prefix(count))
                        guard data.count <= 8 * 1024 * 1024 else { throw NativeDockError.message("Dock 偏好导出超出读取范围。") }
                    } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR { throw NativeDockError.message("独立 Dock 偏好读取失败。") }
                }
            }
            if !process.isRunning {
                guard process.terminationStatus == 0,
                      let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw NativeDockError.message("无法独立核对 Dock 偏好。")
                }
                return values
            }
        }
        throw NativeDockError.message("独立 Dock 偏好读取超时，已停止更改。")
    }

    static func write(_ value: NativeDockPreferenceValue, key: String) throws {
        guard allowedKeys.contains(key) else { throw NativeDockError.message("拒绝写入不属于本次恢复范围的偏好。") }
        CFPreferencesSetValue(key as CFString, try value.decoded() as CFPropertyList?, domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func effectiveValue(_ key: String) throws -> NativeDockPreferenceValue {
        // 本进程写入后 CFPreferences 缓存可能还是旧值；先同步，再读，避免把成功写入误判为失败。
        CFPreferencesAppSynchronize(domain as CFString)
        return try .encoding(CFPreferencesCopyAppValue(key as CFString, domain as CFString))
    }

    /// 当前值仍等于本工具写入值才恢复；后来更改过的字段保留当前值。本应用持续调整的键只要改过就写回原值。
    static func restoreCandidates(_ session: NativeDockRecoverySession,
                                  current: [String: NativeDockPreferenceValue]) -> [NativeDockPreferenceChange] {
        session.changes.filter { change in
            guard session.attemptedKeys.contains(change.key) else { return false }
            if isManaged(change.key, in: session) { return current[change.key] != change.original }
            return change.original != change.applied && current[change.key] == change.applied
        }
    }

    /// 必须持有会话锁。UUID 不匹配时只返回，旧恢复子进程不能覆盖新会话。
    @discardableResult
    static func restoreLocked(at location: Location, expectedID: UUID) throws -> Bool {
        guard FileManager.default.fileExists(atPath: location.state.path) else { return false }
        var session = try load(location.state)
        guard session.id == expectedID, session.phase != .inactive else { return false }
        let baseline = try load(location.backup(session.id))
        guard baseline.id == session.id, baseline.changes == session.changes,
              baseline.mainPID == session.mainPID, baseline.mainIdentity == session.mainIdentity else {
            throw NativeDockError.message("Dock 恢复备份与当前会话不一致。")
        }
        try synchronize()
        var current: [String: NativeDockPreferenceValue] = [:]
        for change in session.changes { current[change.key] = try read(change.key) }
        let candidates = restoreCandidates(session, current: current)
        session.phase = .restoring
        try save(session, at: location.state)
        for change in candidates {
            // 再读一次，缩小与用户手动修改同时发生时的竞争窗口。
            let now = try read(change.key)
            guard isManaged(change.key, in: session) ? now != change.original : now == change.applied else { continue }
            try write(change.original, key: change.key)
            try synchronize()
            guard try read(change.key) == change.original else {
                throw NativeDockError.message("\(change.key) 恢复后的值核对失败；备份仍然保留。")
            }
            if !session.restoredKeys.contains(change.key) { session.restoredKeys.append(change.key) }
            try save(session, at: location.state)
        }
        session.preservedKeys = session.attemptedKeys.filter { key in
            !session.restoredKeys.contains(key) && session.changes.first(where: { $0.key == key })?.original != current[key]
        }
        // 即使上次恢复在写值后崩溃，也需要重新加载 Dock 使已恢复的偏好生效。
        if !session.attemptedKeys.isEmpty { try restartCurrentUserDock() }
        session.phase = .inactive
        session.finishedAt = Date()
        try save(session, at: location.state)
        return true
    }

    static func restartCurrentUserDock() throws {
        let intended = try independentPreferences()
        let oldPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: domain).compactMap { app -> Int32? in
            guard DockStopGuardIdentity.captureDock(app.processIdentifier) != nil else { return nil }
            return app.processIdentifier
        })
        guard !oldPIDs.isEmpty else { throw NativeDockError.message("未找到可核验的本用户系统 Dock。") }
        // 正常退出的 Dock 会把内存中的固定项写回偏好，覆盖刚写入的值；强制重载让新进程只读取偏好。
        for pid in oldPIDs {
            if kill(pid, SIGKILL) != 0 && errno != ESRCH {
                throw NativeDockError.message("无法重新加载当前用户的系统 Dock。")
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var stable = 0
        var mismatched: [String] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            var pids = [pid_t](repeating: 0, count: max(0, Int(size)) / MemoryLayout<pid_t>.size + 32)
            let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
            let newDock = pids.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).contains {
                !oldPIDs.contains($0) && DockStopGuardIdentity.captureDock($0) != nil
            }
            let actual = try independentPreferences()
            mismatched = try allowedKeys.filter { try NativeDockPreferenceValue.encoding(actual[$0]) != NativeDockPreferenceValue.encoding(intended[$0]) }.sorted()
            stable = newDock && mismatched.isEmpty ? stable + 1 : 0
            if stable >= 3 { return }
            Thread.sleep(forTimeInterval: 0.12)
        }
        throw NativeDockError.message("新系统 Dock 未稳定采用预期设置（\(mismatched.isEmpty ? "未检测到新进程" : mismatched.joined(separator: "、"))），恢复记录仍保留。")
    }

    static func validateWatcherSession(at location: Location, backupURL: URL,
                                       id: UUID, pid: Int32, identity: String) throws -> Bool {
        guard location.backup(id).standardizedFileURL == backupURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: location.state.path) else { return false }
        let current = try load(location.state)
        return current.id == id && current.mainPID == pid && current.mainIdentity == identity && current.phase != .inactive
    }

    /// 纯内存 fixture：不读写 Dock 偏好、不终止任何进程。
    static func selfTest() throws -> String {
        let absent = NativeDockPreferenceValue(data: nil)
        let off = try NativeDockPreferenceValue.encoding(false)
        let on = try NativeDockPreferenceValue.encoding(true)
        let short = try NativeDockPreferenceValue.encoding(0.5)
        let long = try NativeDockPreferenceValue.encoding(3600.0)
        let custom = try NativeDockPreferenceValue.encoding(9.0)
        let changes = [NativeDockPreferenceChange(key: "autohide", original: off, applied: on),
                       NativeDockPreferenceChange(key: "autohide-delay", original: absent, applied: long)]
        var session = NativeDockRecoverySession(version: 1, id: UUID(), mainPID: getpid(),
                                               mainIdentity: processIdentity(getpid()) ?? "test", userID: getuid(),
                                               createdAt: Date(), changes: changes, phase: .active,
                                               attemptedKeys: ["autohide", "autohide-delay"], restoredKeys: [], preservedKeys: [])
        func check(_ condition: Bool, _ description: String) throws {
            if !condition { throw NativeDockError.message("恢复 fixture 失败：\(description)") }
        }
        let both = restoreCandidates(session, current: ["autohide": on, "autohide-delay": long])
        try check(both.count == 2, "未变更字段均恢复")
        try check(both.first(where: { $0.key == "autohide-delay" })?.original.data == nil, "原来不存在的键应删除")
        try check(restoreCandidates(session, current: ["autohide": off, "autohide-delay": custom]).isEmpty, "用户后来改动均保留")
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": custom]).map(\.key) == ["autohide"], "逐字段恢复")
        session.attemptedKeys = ["autohide"]
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": long]).map(\.key) == ["autohide"], "未写入字段不恢复")
        session.attemptedKeys = []
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": long]).isEmpty, "准备阶段崩溃不写偏好")
        try check(try NativeDockPreferenceValue.encoding(short.decoded()) == short, "数值备份往返")
        try check(try NativeDockPreferenceValue.encoding(absent.decoded()) == absent, "不存在值备份往返")
        try check(ownerIsAlive(session), "主进程开始时间身份核对")
        let genie = try NativeDockPreferenceValue.encoding("genie")
        let scale = try NativeDockPreferenceValue.encoding("scale")
        let instant = try NativeDockPreferenceValue.encoding(0.001)
        session = NativeDockRecoverySession(version: 2, id: UUID(), mainPID: getpid(),
            mainIdentity: processIdentity(getpid()) ?? "test", userID: getuid(), createdAt: Date(),
            changes: changes + [NativeDockPreferenceChange(key: "mineffect", original: scale, applied: genie),
                                NativeDockPreferenceChange(key: "genie-speed", original: absent, applied: instant)],
            phase: .active, attemptedKeys: ["autohide", "autohide-delay", "mineffect", "genie-speed"],
            restoredKeys: [], preservedKeys: [])
        let allFour = restoreCandidates(session, current: ["autohide": on, "autohide-delay": long, "mineffect": genie, "genie-speed": instant])
        try check(allFour.count == 4, "四字段会话均恢复")
        try check(allFour.first(where: { $0.key == "genie-speed" })?.original.data == nil, "动画速度原缺失时删除")
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": long, "mineffect": scale, "genie-speed": custom]).count == 2, "保留用户后来改动的动画偏好")
        try check(try NativeDockPreferenceValue.encoding(scale.decoded()) == scale, "字符串动画偏好往返")
        let data = try PropertyListEncoder().encode(session)
        let roundtrip = try PropertyListDecoder().decode(NativeDockRecoverySession.self, from: data)
        try check(roundtrip.version == 2 && roundtrip.changes == session.changes, "新版会话编码往返")
        try check(legacyKeys.isSubset(of: allowedKeys) && animationKeys.isDisjoint(with: legacyKeys), "旧版恢复键范围兼容")
        let spacer = try NativeDockPreferenceValue.encoding([["tile-type": "small-spacer-tile", "tile-data": [String: Any]()]])
        let spacerWithGUID = try NativeDockPreferenceValue.encoding([["GUID": 42, "tile-type": "small-spacer-tile", "tile-data": ["file-label": ""]]])
        let appTile = try NativeDockPreferenceValue.encoding([["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.mail"]]])
        try check(spacer == spacerWithGUID, "Dock 补写 GUID 后固定项仍视为相同")
        try check(spacer != appTile, "不同固定项不能视为相同")
        let size37 = try NativeDockPreferenceValue.encoding(37.0), size31 = try NativeDockPreferenceValue.encoding(31.2)
        session = NativeDockRecoverySession(version: 4, id: UUID(), mainPID: getpid(),
            mainIdentity: processIdentity(getpid()) ?? "test", userID: getuid(), createdAt: Date(),
            changes: changes + [NativeDockPreferenceChange(key: "tilesize", original: size37, applied: size37)],
            phase: .active, attemptedKeys: ["autohide", "autohide-delay"], restoredKeys: [], preservedKeys: [])
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": long, "tilesize": size31]).count == 2, "未登记调整的图标尺寸不恢复")
        session.attemptedKeys.append("tilesize")
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": long, "tilesize": size31]).map(\.key).contains("tilesize"), "运行中调整过的图标尺寸写回原值")
        try check(restoreCandidates(session, current: ["autohide": on, "autohide-delay": long, "tilesize": size37]).count == 2, "图标尺寸已是原值时不重复写")
        return "通过 20 项恢复 fixture：影子模式固定项按内容比较、v1 两字段与 v2 四字段条件恢复、v4 图标尺寸调整后写回原值、用户更改保留、原缺失键删除、部分写入、备份往返与 PID 身份。未修改系统偏好。"
    }
}

@MainActor
final class NativeDockCoordinator {
    private let location: NativeDockRecovery.Location
    private let watchdogExecutable: URL
    private var sessionID: UUID?
    private var watchdog: Process?
    private var animationRecoveryTask: Task<Void, Never>?
    private var entered = false
    var isActive: Bool {
        guard entered, let sessionID, let session = try? NativeDockRecovery.load(location.state) else { return false }
        return session.id == sessionID && session.phase != .inactive
    }

    init(dataDirectory: URL, watchdogExecutable: URL) {
        location = NativeDockRecovery.Location(dataDirectory: dataDirectory)
        self.watchdogExecutable = watchdogExecutable
    }

    struct ShadowConfiguration: Equatable, Sendable {
        var tileSize: Double
        var orientation: String
    }
    private(set) var shadow: ShadowConfiguration?

    func enter(suppressNativeMinimization: Bool = false, shadow: ShadowConfiguration? = nil) throws {
        if isActive { return }
        guard FileManager.default.isExecutableFile(atPath: watchdogExecutable.path),
              let identity = NativeDockRecovery.processIdentity(getpid()) else {
            throw NativeDockError.message("恢复子进程不可执行或主进程身份无法核对，未隐藏系统 Dock。")
        }
        let id = UUID()
        try NativeDockRecovery.withLock(at: location) {
            if FileManager.default.fileExists(atPath: location.state.path) {
                let previous = try NativeDockRecovery.load(location.state)
                if previous.phase != .inactive {
                    guard !NativeDockRecovery.ownerIsAlive(previous) else {
                        throw NativeDockError.message("另一个 Dock 文件夹会话正在管理系统 Dock。")
                    }
                    try NativeDockRecovery.restoreLocked(at: location, expectedID: previous.id)
                }
            }
            try NativeDockRecovery.synchronize()
            var changes: [NativeDockPreferenceChange]
            if let shadow {
                // 固定项为空时系统 Dock 会自动填回旧列表；保留一个小间隔即可让它只显示访达、运行中应用和废纸篓。
                changes = try [
                    NativeDockPreferenceChange(key: "autohide", original: NativeDockRecovery.read("autohide"), applied: .encoding(false)),
                    NativeDockPreferenceChange(key: "persistent-apps", original: NativeDockRecovery.read("persistent-apps"), applied: .encoding([["tile-type": "small-spacer-tile", "tile-data": [String: Any]()]])),
                    NativeDockPreferenceChange(key: "persistent-others", original: NativeDockRecovery.read("persistent-others"), applied: .encoding([Any]())),
                    NativeDockPreferenceChange(key: "show-recents", original: NativeDockRecovery.read("show-recents"), applied: .encoding(false)),
                    NativeDockPreferenceChange(key: "magnification", original: NativeDockRecovery.read("magnification"), applied: .encoding(false)),
                    NativeDockPreferenceChange(key: "tilesize", original: NativeDockRecovery.read("tilesize"), applied: .encoding(shadow.tileSize)),
                    NativeDockPreferenceChange(key: "orientation", original: NativeDockRecovery.read("orientation"), applied: .encoding(shadow.orientation))
                ]
            } else {
                changes = try [
                    NativeDockPreferenceChange(key: "autohide", original: NativeDockRecovery.read("autohide"),
                                               applied: .encoding(true)),
                    // 碰不出来靠各屏底边的鼠标移动拦截；延迟只作兜底。推边换屏要压满约一个延迟（实测 1 秒推 0.5 秒即换屏，
                    // 2 秒要推约 2.6 秒，3600 秒推不动），启动时还要把它挪到应用栏所在屏，所以只设 1 秒。
                    NativeDockPreferenceChange(key: "autohide-delay", original: NativeDockRecovery.read("autohide-delay"),
                                               applied: .encoding(1.0))
                ]
                // 图标尺寸进入时不改，运行中按应用栏对齐（见 beginManaging）。
                if !suppressNativeMinimization {
                    let size = try NativeDockRecovery.read("tilesize")
                    changes.append(NativeDockPreferenceChange(key: "tilesize", original: size, applied: size))
                }
            }
            if suppressNativeMinimization, shadow == nil {
                changes += try [
                    NativeDockPreferenceChange(key: "mineffect", original: NativeDockRecovery.read("mineffect"), applied: .encoding("genie")),
                    NativeDockPreferenceChange(key: "genie-speed", original: NativeDockRecovery.read("genie-speed"), applied: .encoding(0.001))
                ]
            }
            let session = NativeDockRecoverySession(version: shadow != nil ? 3 : (suppressNativeMinimization ? 2 : 4), id: id, mainPID: getpid(), mainIdentity: identity,
                                                   userID: getuid(), createdAt: Date(), changes: changes,
                                                   phase: .prepared, attemptedKeys: [], restoredKeys: [], preservedKeys: [])
            try NativeDockRecovery.save(session, at: location.backup(id))
            try NativeDockRecovery.save(session, at: location.state)
        }
        sessionID = id
        do {
            try launchWatchdog(id: id, identity: identity)
            try NativeDockRecovery.withLock(at: location) {
                var session = try NativeDockRecovery.load(location.state)
                guard session.id == id else { throw NativeDockError.message("Dock 恢复会话已变化，取消启用。") }
                for change in session.changes {
                    try NativeDockRecovery.synchronize()
                    guard try NativeDockRecovery.read(change.key) == change.original else {
                        throw NativeDockError.message("Dock 设置在启用期间被更改，已取消隐藏。")
                    }
                    if change.original == change.applied { continue }
                    // 写前持久化意图，主程序即使在下一行后崩溃，watchdog 也能按字段恢复。
                    session.attemptedKeys.append(change.key)
                    try NativeDockRecovery.save(session, at: location.state)
                    try NativeDockRecovery.write(change.applied, key: change.key)
                    try NativeDockRecovery.synchronize()
                    guard try NativeDockRecovery.read(change.key) == change.applied,
                          try NativeDockRecovery.effectiveValue(change.key) == change.applied else {
                        throw NativeDockError.message("系统 Dock 设置写入核对失败，可能存在受管理或主机专用设置。")
                    }
                }
                session.phase = .active
                try NativeDockRecovery.save(session, at: location.state)
                if !session.attemptedKeys.isEmpty { try NativeDockRecovery.restartCurrentUserDock() }
            }
            entered = true
            self.shadow = shadow
        } catch {
            let originalError = error
            do { try restore() }
            catch {
                throw NativeDockError.message("启用失败：\(originalError.localizedDescription) 恢复尚未通过核对：\(error.localizedDescription) 恢复备份：\(location.backup(id).path)")
            }
            throw originalError
        }
    }

    func restore() throws {
        animationRecoveryTask?.cancel(); animationRecoveryTask = nil
        guard let sessionID else { return }
        _ = try NativeDockRecovery.withLock(at: location) {
            try NativeDockRecovery.restoreLocked(at: location, expectedID: sessionID)
        }
        self.sessionID = nil
        entered = false
        shadow = nil
        // 子进程在看到 inactive 或新的 UUID 后自行退出，不安装常驻组件。
        watchdog = nil
    }

    /// 运行中第一次调整受管键（隐藏系统 Dock 的图标尺寸）前登记为已尝试，之后退出或崩溃都会写回原值。
    func beginManaging(_ key: String) throws {
        guard let sessionID else { throw NativeDockError.message("系统 Dock 会话未启用。") }
        try NativeDockRecovery.withLock(at: location) {
            var session = try NativeDockRecovery.load(location.state)
            guard session.id == sessionID, session.phase == .active, NativeDockRecovery.isManaged(key, in: session) else {
                throw NativeDockError.message("当前会话不允许调整 \(key)。")
            }
            guard !session.attemptedKeys.contains(key) else { return }
            session.attemptedKeys.append(key)
            try NativeDockRecovery.save(session, at: location.state)
        }
    }

    /// 屏幕捕获失效时立即归还原生动画；隐藏会话仍然有效，watchdog 仍能恢复其余字段。
    func resumeNativeMinimizationAnimations() throws {
        guard let sessionID else { return }
        try NativeDockRecovery.withLock(at: location) {
            var session = try NativeDockRecovery.load(location.state)
            guard session.id == sessionID, session.phase == .active else { return }
            try NativeDockRecovery.synchronize()
            var changed = false
            for change in session.changes where NativeDockRecovery.animationKeys.contains(change.key) {
                guard session.attemptedKeys.contains(change.key), try NativeDockRecovery.read(change.key) == change.applied,
                      change.original != change.applied else { continue }
                try NativeDockRecovery.write(change.original, key: change.key)
                try NativeDockRecovery.synchronize()
                guard try NativeDockRecovery.read(change.key) == change.original else {
                    throw NativeDockError.message("窗口捕获失效后无法恢复 \(change.key)，恢复备份仍然保留。")
                }
                if !session.restoredKeys.contains(change.key) { session.restoredKeys.append(change.key) }
                changed = true
                try NativeDockRecovery.save(session, at: location.state)
            }
            if changed {
                // AXMiniaturized 回调可能先于 Dock 完成最小化事务；立即重启会让原窗口被意外重新展开。
                // 先精确归还偏好，再等在途事务结束重载。退出时 restore 会取消此任务并自行重载。
                animationRecoveryTask?.cancel()
                animationRecoveryTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, isActive, !Task.isCancelled else { return }
                    do { try NativeDockRecovery.restartCurrentUserDock() }
                    catch { NSLog("Dock 原生动画恢复重载失败：%@", error.localizedDescription) }
                    animationRecoveryTask = nil
                }
            }
        }
    }

    private func launchWatchdog(id: UUID, identity: String) throws {
        let ready = Pipe()
        let process = Process()
        process.executableURL = watchdogExecutable
        process.arguments = ["--parent-pid", String(getpid()), "--parent-identity", identity,
                             "--session", id.uuidString, "--backup", location.backup(id).path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? ready.fileHandleForWriting.close()
        defer { try? ready.fileHandleForReading.close() }
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 3000) > 0,
              let message = try ready.fileHandleForReading.read(upToCount: 6),
              String(data: message, encoding: .utf8) == "READY\n", process.isRunning else {
            throw NativeDockError.message("恢复子进程未通过启动握手，未隐藏系统 Dock。")
        }
        watchdog = process
    }
}
