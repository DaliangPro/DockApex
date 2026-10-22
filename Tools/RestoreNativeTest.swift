import AppKit
import Foundation

// 原生 Dock 测试的定向恢复工具；默认只核对，传入 --apply 才写入。
// 只写当前用户 com.apple.dock 的 persistent-apps，不删除应用或文件。
enum RestoreError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct RestoreSnapshot {
    let url: URL
    let createdAt: Date
    let before: [[String: Any]]
    let groupsBefore: [Any]
}

let files = FileManager.default
let root = URL(fileURLWithPath: files.currentDirectoryPath, isDirectory: true).standardizedFileURL
let dataRoot = root.appendingPathComponent("Data", isDirectory: true)
let entriesRoot = dataRoot.appendingPathComponent("Entries", isDirectory: true).resolvingSymlinksInPath()
let backupsRoot = dataRoot.appendingPathComponent("Backups", isDirectory: true)
let groupsURL = dataRoot.appendingPathComponent("groups.json")
let latestURL = backupsRoot.appendingPathComponent("latest.plist")
let appID = "com.apple.dock" as CFString
let fixedKey = "persistent-apps" as CFString

func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

func appURL(_ tile: [String: Any]) -> URL? {
    guard tile["tile-type"] as? String == "file-tile",
          let data = tile["tile-data"] as? [String: Any],
          let file = data["file-data"] as? [String: Any],
          let value = file["_CFURLString"] as? String else { return nil }
    if value.hasPrefix("file:") { return URL(string: value) }
    if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
    return nil
}

func identity(_ tile: [String: Any]) -> String {
    if let url = appURL(tile) { return "app:" + normalizedPath(url) }
    return "other:\(tile["tile-type"] as? String ?? "unknown"):\(String(describing: tile["GUID"] ?? ""))"
}

func isGeneratedEntry(_ tile: [String: Any]) -> Bool {
    guard let url = appURL(tile) else { return false }
    let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
    guard normalized.pathExtension.lowercased() == "app",
          normalizedPath(normalized.deletingLastPathComponent()) == normalizedPath(entriesRoot),
          let id = UUID(uuidString: normalized.deletingPathExtension().lastPathComponent),
          let storedID = Bundle(url: normalized)?.object(forInfoDictionaryKey: "DockFoldersGroupID") as? String,
          UUID(uuidString: storedID) == id else { return false }
    return true
}

func readFixedItems() throws -> [[String: Any]] {
    guard CFPreferencesAppSynchronize(appID),
          let fixed = CFPreferencesCopyAppValue(fixedKey, appID) as? [[String: Any]] else {
        throw RestoreError.message("无法同步并读取当前用户 Dock 固定项。")
    }
    return fixed
}

func writeFixedItems(_ fixed: [[String: Any]]) throws {
    CFPreferencesSetAppValue(fixedKey, fixed as CFArray, appID)
    guard CFPreferencesAppSynchronize(appID) else {
        throw RestoreError.message("Dock 固定项同步失败。")
    }
    let actual = try readFixedItems()
    guard NSArray(array: actual).isEqual(NSArray(array: fixed)) else {
        throw RestoreError.message("Dock 固定项写入后的完整字典回读不一致。")
    }
}

func ensureOriginalAppsStopped() throws {
    let conflicts = NSWorkspace.shared.runningApplications.filter { app in
        let identifier = app.bundleIdentifier?.lowercased() ?? ""
        let executable = app.executableURL?.lastPathComponent.lowercased() ?? ""
        let bundlePath = app.bundleURL.map(normalizedPath) ?? ""
        return identifier.hasPrefix("local.dockfolders")
            || identifier.contains("dockprobe")
            || executable == "dockfolders"
            || executable == "groupentry"
            || executable.hasPrefix("dockprobe")
            || bundlePath.hasPrefix(normalizedPath(root.appendingPathComponent("prototypes/dock-drag-probe")) + "/")
    }
    guard conflicts.isEmpty else {
        throw RestoreError.message("原产品或探针仍在运行，已停止恢复：" + conflicts.map { "\($0.localizedName ?? "应用") (PID \($0.processIdentifier))" }.joined(separator: "、"))
    }
}

func earliestSnapshot() throws -> RestoreSnapshot {
    let urls = try files.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)
    let valid: [RestoreSnapshot] = urls.compactMap { url in
        guard url.pathExtension == "plist", url.lastPathComponent != "latest.plist",
              let bytes = try? Data(contentsOf: url),
              let backup = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              backup["failed"] as? Bool != true,
              let createdAt = backup["createdAt"] as? Date,
              let before = backup["before"] as? [[String: Any]],
              backup["after"] is [[String: Any]],
              let groupsBytes = backup["groupsBefore"] as? Data,
              let groups = try? JSONSerialization.jsonObject(with: groupsBytes) as? [Any] else { return nil }
        return RestoreSnapshot(url: url, createdAt: createdAt, before: before, groupsBefore: groups)
    }
    guard let first = valid.min(by: { $0.createdAt < $1.createdAt }),
          first.before.count == 19, first.groupsBefore.isEmpty,
          !first.before.contains(where: isGeneratedEntry) else {
        throw RestoreError.message("找不到符合首次测试前 19 项、空分组条件的有效快照，未作更改。")
    }
    return first
}

func restartDock() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["-u", NSUserName(), "Dock"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RestoreError.message("当前用户 Dock 重启请求失败。")
    }
    for _ in 0..<30 {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.dock" }) { return }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw RestoreError.message("Dock 重启后未在期限内重新出现。")
}

do {
    try ensureOriginalAppsStopped()
    let snapshot = try earliestSnapshot()
    let current = try readFixedItems()
    let retained = current.filter { !isGeneratedEntry($0) }
    guard retained.map(identity) == snapshot.before.map(identity) else {
        throw RestoreError.message("剔除本项目生成入口后，当前固定项身份或顺序与首次测试前不一致，可能存在其他修改；没有覆盖。")
    }
    let originalGroupsBytes = try Data(contentsOf: groupsURL)
    guard let currentConfiguration = try JSONSerialization.jsonObject(with: originalGroupsBytes) as? [String: Any],
          let currentGroups = currentConfiguration["groups"] as? [Any],
          currentConfiguration["version"] as? Int == 1 else {
        throw RestoreError.message("当前分组配置无法有效读取，未作更改。")
    }
    let latestBytes = try Data(contentsOf: latestURL)
    guard var latest = try PropertyListSerialization.propertyList(from: latestBytes, format: nil) as? [String: Any] else {
        throw RestoreError.message("最新撤销记录无效，未作更改。")
    }
    print("核对通过：原产品与探针未运行；当前 \(current.count) 个固定项，其中项目生成入口 \(current.count - retained.count) 个；原固定项 19 个，身份及顺序匹配。")
    print("恢复依据：\(snapshot.url.lastPathComponent)；分组 \(currentGroups.count) → \(snapshot.groupsBefore.count)。")
    guard CommandLine.arguments.contains("--apply") else {
        print("仅完成只读核对；传入 --apply 执行恢复。")
        exit(EXIT_SUCCESS)
    }

    // 每项变更前，保留完整的当前固定项、配置原文及最新撤销记录。
    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let diagnostics = dataRoot.appendingPathComponent("Diagnostics", isDirectory: true)
        .appendingPathComponent("\(timestamp)-原生Dock测试恢复-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try files.createDirectory(at: diagnostics, withIntermediateDirectories: true)
    let fixedBackup = try PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0)
    try fixedBackup.write(to: diagnostics.appendingPathComponent("persistent-apps-before.plist"), options: .atomic)
    try originalGroupsBytes.write(to: diagnostics.appendingPathComponent("groups-before.json"), options: .atomic)
    try latestBytes.write(to: diagnostics.appendingPathComponent("latest-before.plist"), options: .atomic)

    let restoredGroupsBytes = try JSONSerialization.data(withJSONObject: ["version": 1, "groups": snapshot.groupsBefore], options: [.prettyPrinted, .sortedKeys])
    latest["undone"] = true
    latest["nativeTestRestoredAt"] = Date()
    latest["nativeTestRestoredFrom"] = snapshot.url.lastPathComponent
    let updatedLatestBytes = try PropertyListSerialization.data(fromPropertyList: latest, format: .binary, options: 0)

    try ensureOriginalAppsStopped()
    let finalCheck = try readFixedItems()
    guard NSArray(array: finalCheck).isEqual(NSArray(array: current)),
          try Data(contentsOf: groupsURL) == originalGroupsBytes,
          try Data(contentsOf: latestURL) == latestBytes else {
        throw RestoreError.message("备份后发现布局、分组配置或撤销记录变化，已停止恢复。")
    }
    var configurationChanged = false
    var layoutChanged = false
    var latestChanged = false
    do {
        try restoredGroupsBytes.write(to: groupsURL, options: .atomic)
        configurationChanged = true
        layoutChanged = true
        try writeFixedItems(snapshot.before)
        try updatedLatestBytes.write(to: latestURL, options: .atomic)
        latestChanged = true
        try restartDock()
        Thread.sleep(forTimeInterval: 0.5)
        let restored = try readFixedItems()
        let restoredConfiguration = try JSONSerialization.jsonObject(with: Data(contentsOf: groupsURL)) as? [String: Any]
        let restoredGroups = restoredConfiguration?["groups"] as? [Any]
        guard restored.map(identity) == snapshot.before.map(identity),
              restored.count == 19,
              !restored.contains(where: isGeneratedEntry),
              restoredGroups?.isEmpty == true else {
            throw RestoreError.message("恢复后的固定项或分组配置核对失败。")
        }
        let result: [String: Any] = [
            "restoredAt": Date(), "snapshot": snapshot.url.lastPathComponent,
            "fixedItems": restored.count, "generatedEntries": 0, "groups": 0,
            "identityAndOrderMatch": true, "fullDictionaryReadbackBeforeRestart": true,
            "latestMarkedUndone": true, "dockRestarted": true
        ]
        let resultBytes = try PropertyListSerialization.data(fromPropertyList: result, format: .xml, options: 0)
        try resultBytes.write(to: diagnostics.appendingPathComponent("restoration-result.plist"), options: .atomic)
        print("已验证恢复：19 个原固定项身份及顺序一致；生成入口 0；分组 0；最新撤销记录已标记 undone；当前用户 Dock 已重启。")
        print("恢复前完整备份与结果：\(diagnostics.path)")
    } catch {
        var rollbackErrors: [String] = []
        if configurationChanged {
            do { try originalGroupsBytes.write(to: groupsURL, options: .atomic) }
            catch { rollbackErrors.append("分组配置回退失败") }
        }
        if layoutChanged {
            do { try writeFixedItems(current); try restartDock() }
            catch { rollbackErrors.append("Dock 布局回退或重启失败") }
        }
        if latestChanged {
            do { try latestBytes.write(to: latestURL, options: .atomic) }
            catch { rollbackErrors.append("撤销记录回退失败") }
        }
        if !rollbackErrors.isEmpty {
            throw RestoreError.message("\(error.localizedDescription)；\(rollbackErrors.joined(separator: "、"))。完整备份：\(diagnostics.path)")
        }
        throw error
    }
} catch {
    fputs("恢复未完成：\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
