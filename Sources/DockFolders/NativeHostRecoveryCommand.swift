import AppKit
import Darwin
import Foundation

/// 在正常应用入口之前处理恢复命令；不创建界面、不启动手势或请求辅助功能。
@MainActor
enum NativeHostRecoveryCommand {
    private struct Failure: Error {
        let code: Int32
        let message: String
    }

    private struct Options {
        var dataDirectory: URL?
        var repairArchive: URL?
        var help = false
    }

    /// 未指定本命令时返回 false。成功或帮助返回 true，错误以明确的非零状态退出。
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--restore-native-host") || arguments.contains("--repair-unpersisted-commit") || arguments.contains("--help") else { return false }
        do {
            let options = try parse(arguments)
            if options.help { printHelp(); return true }
            let bundle = Bundle.main
            guard bundle.bundleIdentifier == "io.daliang.dockfolders", bundle.bundleURL.pathExtension == "app" else {
                throw Failure(code: 69, message: "请使用项目 build/DockFolders.app 内的主程序执行恢复命令。")
            }
            let dataDirectory: URL
            if let explicit = options.dataDirectory { dataDirectory = explicit }
            else if let root = bundle.object(forInfoDictionaryKey: "WorkspaceRoot") as? String, root.hasPrefix("/") {
                dataDirectory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Data", isDirectory: true)
            } else {
                throw Failure(code: 69, message: "无法确定项目数据目录；请传入 --data-directory 和项目 Data 的绝对路径。")
            }
            try stopRunningMainApplications()
            GroupEntryRuntimeCoordinator.stopOwnedEntries(dataDirectory: dataDirectory)
            if let archive = options.repairArchive {
                try repairArchivedCommit(archive: archive, dataDirectory: dataDirectory)
                return true
            }
            let state = dataDirectory.appendingPathComponent("native-host-session.plist")
            guard FileManager.default.fileExists(atPath: state.path) else {
                print("没有本工具的原生分组承载会话，无需恢复分组固定项。")
                return true
            }
            // 构造器仅加载并核验备份。恢复时不调用 install/start，也不生成分组入口。
            let proxy = bundle.bundleURL.appendingPathComponent("Contents/Resources/GroupEntry")
            let host = try NativeDockHostController(dataDirectory: dataDirectory,
                mainAppURL: bundle.bundleURL, proxyExecutable: proxy,
                onMerge: { _, _ in }, onStatus: { print($0) })
            // 在提交前再检查一次，防止等待期间主应用被分组入口重新启动。
            guard try runningMainApplications().isEmpty else {
                throw Failure(code: 75, message: "主应用在恢复前重新启动，已停止修改；请关闭它后再运行恢复入口。")
            }
            try host.restoreOriginalIfUnchanged()
            print("原生分组条件恢复检查已完成；不会覆盖分组后由您另外调整的 Dock 项目。")
            print("分组会话与备份保留在：\(state.path) 和 \(dataDirectory.appendingPathComponent("Backups").path)")
            return true
        } catch let failure as Failure {
            fail(failure.message, code: failure.code)
        } catch {
            fail("原生分组恢复未完成：\(error.localizedDescription)；备份仍保留，请勿删除项目 Data。", code: 74)
        }
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var requested = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--help": result.help = true
            case "--restore-native-host":
                guard !requested else { throw Failure(code: 64, message: "--restore-native-host 不应重复。") }
                requested = true
            case "--repair-unpersisted-commit":
                guard !requested, index + 1 < arguments.count,
                      arguments[index + 1].hasPrefix("/"), !arguments[index + 1].contains("\0") else {
                    throw Failure(code: 64, message: "--repair-unpersisted-commit 必须单独指定，并跟随完整归档目录的绝对路径。")
                }
                requested = true
                index += 1
                result.repairArchive = URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL
            case "--data-directory":
                guard result.dataDirectory == nil, index + 1 < arguments.count,
                      arguments[index + 1].hasPrefix("/"), !arguments[index + 1].contains("\0") else {
                    throw Failure(code: 64, message: "--data-directory 必须跟随一个项目 Data 的绝对路径。")
                }
                index += 1
                result.dataDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL
            default: throw Failure(code: 64, message: "存在不支持的恢复参数。请使用 --help 查看用法。")
            }
            index += 1
        }
        guard requested || result.help else { throw Failure(code: 64, message: "缺少恢复操作参数。") }
        return result
    }

    /// 只补回操作者明确指定的未落地事务；不扫描历史备份，不覆盖当前分组配置。
    private static func repairArchivedCommit(archive: URL, dataDirectory: URL) throws {
        let archive = archive.resolvingSymlinksInPath()
        let dataDirectory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let archiveRoot = dataDirectory.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true).resolvingSymlinksInPath()
        guard archive.deletingLastPathComponent() == archiveRoot else {
            throw Failure(code: 64, message: "补回事务只接受当前项目 Backups 下明确指定的完整归档目录。")
        }
        let archivedState = try NativeDockHostState.load(archive.appendingPathComponent("native-host-session.plist"))
        struct CurrentShelf: Decodable { let configuration: ShelfConfiguration }
        let shelf = try JSONDecoder().decode(CurrentShelf.self, from: Data(contentsOf: dataDirectory.appendingPathComponent("shelf.json")))
        let archivedShelf = try JSONDecoder().decode(CurrentShelf.self, from: Data(contentsOf: archive.appendingPathComponent("shelf.json")))
        let groups = shelf.configuration.groups
        let ids = Set(groups.map { $0.id.uuidString })
        let entries = dataDirectory.appendingPathComponent("Entries", isDirectory: true)
        let paths = Set(groups.map { DockLayout.normalizedPath(entries.appendingPathComponent($0.id.uuidString + ".app")) })
        guard shelf.configuration.version == 1, archivedShelf.configuration.version == 1,
              archivedShelf.configuration.groups == groups, archivedState.active, archivedState.pending == nil,
              archivedState.migratedIDs == ids, archivedState.entryPaths == paths else {
            throw Failure(code: 74, message: "归档事务与当前分组身份不一致，未修改真实 Dock。")
        }
        for group in groups {
            let entry = entries.appendingPathComponent(group.id.uuidString + ".app")
            guard let bundle = Bundle(url: entry),
                  bundle.bundleIdentifier == "local.dockfolders.group." + group.id.uuidString.lowercased(),
                  bundle.object(forInfoDictionaryKey: "DockFoldersGroupID") as? String == group.id.uuidString else {
                throw Failure(code: 74, message: "分组入口身份核对失败，未修改真实 Dock。")
            }
        }
        guard try runningMainApplications().isEmpty else {
            throw Failure(code: 75, message: "主应用重新启动，补回事务已停止。")
        }
        let integration = try DockIntegration(backupsDirectory: dataDirectory.appendingPathComponent("Backups", isDirectory: true))
        guard try integration.repairArchivedUnpersistedCommit(transactionURL: archive.appendingPathComponent("latest.plist"), expectedAfter: archivedState.lastApplied) else {
            throw Failure(code: 74, message: "当前 Dock 与该笔未落地事务不匹配，未补回任何入口。")
        }
        print("已补回指定未落地事务，并由新系统 Dock 进程稳定核对；当前分组数据与其它固定项已保留。")
    }

    private static func runningMainApplications() throws -> [NSRunningApplication] {
        guard let executable = Bundle.main.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw Failure(code: 69, message: "无法核对当前主程序路径，已停止恢复。")
        }
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard byteCount > 0 else { throw Failure(code: 75, message: "无法读取主程序进程列表，已停止恢复。") }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 32)
        let received = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard received > 0 else { throw Failure(code: 75, message: "主程序进程列表读取失败，已停止恢复。") }
        // 正常退出后 LaunchServices 可短暂保留旧实例；以真实进程身份核对，避免误报重新启动。
        return try pids.prefix(Int(received) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            var info = proc_bsdinfo()
            let length = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length,
                  info.pbi_uid == getuid() else { return nil }
            var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard count > 0, String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) == executable else { return nil }
            guard let application = NSRunningApplication(processIdentifier: pid) else {
                throw Failure(code: 75, message: "发现主程序仍在运行但无法请求正常退出，已停止恢复。")
            }
            return application
        }
    }

    private static func stopRunningMainApplications() throws {
        let applications = try runningMainApplications()
        guard !applications.isEmpty else { return }
        print("正在请求 DockFolders 正常退出；分组暂时保留，随后执行条件恢复。")
        for application in applications {
            guard application.terminate() else {
                throw Failure(code: 75, message: "主应用未接受正常退出请求，已停止恢复；没有强制结束进程。")
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while try !runningMainApplications().isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure(code: 75, message: "等待主应用正常退出超过 10 秒，已停止恢复；没有强制结束进程。")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    private static func printHelp() {
        print("""
        DockFolders 原生 Dock 分组恢复

        用法：DockFolders --restore-native-host [--data-directory <项目 Data 的绝对路径>]
              DockFolders --repair-unpersisted-commit <项目 Backups 下的完整归档目录>
              DockFolders --help

        先请求同一应用正常退出，最多等待 10 秒；没有强制结束进程。
        随后只恢复本工具分组对应的固定项，保留您后来调整的其他 Dock 项目。
        本命令不创建界面、不请求辅助功能、不恢复整份系统偏好设置。
        旧版隐藏配置由 RestoreDock.command 接着调用 DockRestoreAgent 条件恢复。

        退出状态：0 已完成检查或无需恢复；64 参数错误；69 运行资源不完整；
                  74 恢复失败；75 主应用拒绝退出、仍在运行或重新启动。
        """)
    }
}
