import AppKit
import Foundation

@MainActor
struct DockDisplayItem {
    let id: String
    let name: String
    let icon: NSImage
    let isRunning: Bool
    let isGroup: Bool
    var section: DockDisplaySection = .applications
    var badge: String? = nil
    var acceptsFileDrops = true
    /// 分组的成员数；拖叠加入分组时据此算出新成员落在分组图标的哪一格。
    var memberCount = 0
}

struct DockExternalDrop: Sendable {
    let urls: [URL]
    let targetID: String?
    let isApplicationReference: Bool
    let copyFiles: Bool
    /// 没有落在某个图标上时，插入到应用栏的这个位置（显示顺序）；nil 表示放到末尾。
    var insertionIndex: Int? = nil
}

enum DockDisplaySection: Sendable { case applications, running, recent, files }

struct GroupConfiguration: Codable {
    var version = 1
    var groups: [AppGroup] = []
}

@MainActor
final class GroupStore {
    let root: URL
    private(set) var groups: [AppGroup] = []
    private var configurationURL: URL { root.appendingPathComponent("groups.json") }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            let configuration = try JSONDecoder().decode(GroupConfiguration.self, from: Data(contentsOf: configurationURL))
            guard configuration.version == 1 else {
                throw DockFoldersError.message("配置来自较新的版本，暂时不能读取。")
            }
            groups = configuration.groups
        }
    }

    func save(_ groups: [AppGroup]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(GroupConfiguration(groups: groups))
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            let previous = try Data(contentsOf: configurationURL)
            try previous.write(to: root.appendingPathComponent("groups.previous.json"), options: .atomic)
        }
        try data.write(to: configurationURL, options: .atomic)
        self.groups = groups
    }
}

enum DockFoldersError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

/// 当前布局与可撤销布局在同一原子文件中提交，写入失败时两者一起保留。
private struct ShelfArchive: Codable {
    var configuration: ShelfConfiguration
    var previous: ShelfConfiguration?
}

@MainActor
final class ShelfStore {
    let root: URL
    private(set) var configuration: ShelfConfiguration
    private(set) var previous: ShelfConfiguration?
    private var fileURL: URL { root.appendingPathComponent("shelf.json") }

    init(root: URL, initial: @autoclosure () -> ShelfConfiguration) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("shelf.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            if let archive = try? JSONDecoder().decode(ShelfArchive.self, from: data) {
                configuration = archive.configuration
                previous = archive.previous
            } else {
                configuration = try JSONDecoder().decode(ShelfConfiguration.self, from: data)
                previous = try? JSONDecoder().decode(ShelfConfiguration.self, from: Data(contentsOf: root.appendingPathComponent("shelf.previous.json")))
            }
            guard configuration.version == 1 else { throw DockFoldersError.message("应用栏配置版本较新，无法读取。") }
        } else {
            configuration = initial()
            previous = nil
        }
        configuration.normalize()
        if previous?.version == 1 { previous?.normalize() } else { previous = nil }
        backUpDaily()
    }

    func save(_ next: ShelfConfiguration, recordUndo: Bool = true) throws {
        guard next.version == 1 else { throw DockFoldersError.message("无法保存不支持的应用栏配置版本。") }
        var next = next
        next.normalize()
        guard next != configuration || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let archive = ShelfArchive(configuration: next, previous: recordUndo ? configuration : previous)
        backUpDaily()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
        previous = archive.previous
        configuration = next
    }

    func undo() throws {
        guard let previous else { return }
        try save(previous)
    }

    /// 撤销快照和当前布局存在同一个文件里，文件坏了两份一起丢。每天第一次保存前把现有文件复制到
    /// ShelfBackups/shelf-日期.json，只留最近 7 天。
    private func backUpDaily() {
        let folder = root.appendingPathComponent("ShelfBackups", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let target = folder.appendingPathComponent("shelf-\(formatter.string(from: Date())).json")
        let files = FileManager.default
        guard files.fileExists(atPath: fileURL.path), !files.fileExists(atPath: target.path) else { return }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? files.copyItem(at: fileURL, to: target)) != nil,
              let names = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.filter({ $0.hasPrefix("shelf-") && $0.hasSuffix(".json") }).sorted().dropLast(7) {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

@MainActor
final class ActivityLog {
    let url: URL
    init(root: URL) { url = root.appendingPathComponent("activity.jsonl") }

    /// 超过约 5 MB 就改名留档（activity-时间.jsonl），只留最近 3 份。
    static let rotationSize: UInt64 = 5_000_000
    static let keptArchives = 3

    func record(_ message: String) {
        let entry = ["time": ISO8601DateFormatter().string(from: Date()), "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        var size: UInt64 = 0
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
            size = try handle.offset()
        } catch { /* 日志失败不影响原生输入。 */ }
        try? handle.close()
        if size > Self.rotationSize { rotate() }
    }

    private func rotate() {
        let folder = url.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        guard (try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("activity-\(stamp).jsonl"))) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        // 时间戳按字典序即时间顺序。
        let archives = names.filter { $0.hasPrefix("activity-") && $0.hasSuffix(".jsonl") }.sorted()
        for name in archives.dropLast(Self.keptArchives) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
