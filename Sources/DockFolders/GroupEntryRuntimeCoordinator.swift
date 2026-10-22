import AppKit

/// 只准备当前项目 Data/Entries 中身份匹配的分组代理，不改 Dock 或任何系统偏好。
@MainActor
final class GroupEntryRuntimeCoordinator {
    private let dataDirectory: URL
    private let entriesDirectory: URL
    private var desiredPaths = Set<String>()
    private var generation = 0
    private var pendingPaths = Set<String>()
    private(set) var preparationFailures: [String: String] = [:]

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        entriesDirectory = dataDirectory.appendingPathComponent("Entries", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// host 成功提交分组后调用；--prepare 只保持代理就绪，不展开任何分组。
    func synchronize(groups: [AppGroup]) {
        generation += 1
        preparationFailures.removeAll()
        desiredPaths = Set(groups.map { entriesDirectory.appendingPathComponent($0.id.uuidString + ".app").path })
        // 同路径的预热若还在进行，应继续复用，不能因紧邻的分组刷新重复启动或终止它。
        pendingPaths.formIntersection(desiredPaths)
        for app in Self.ownedApplications(dataDirectory: dataDirectory) {
            if let path = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path, !desiredPaths.contains(path) { _ = app.terminate() }
        }
        let token = generation
        for path in desiredPaths { prepare(URL(fileURLWithPath: path), generation: token, attempt: 0) }
    }

    /// 普通退出与显式恢复均停止自有代理，避免“退出工具”后留下常驻进程。
    func stop() {
        generation += 1
        pendingPaths.removeAll()
        desiredPaths.removeAll()
        _ = Self.stopOwnedEntries(dataDirectory: dataDirectory)
    }

    /// 返回系统接受 terminate 请求的数量；调用方仍须另行核实进程已经退出。
    @discardableResult
    static func stopOwnedEntries(dataDirectory: URL) -> Int {
        ownedApplications(dataDirectory: dataDirectory).reduce(0) { $0 + ($1.terminate() ? 1 : 0) }
    }

    private func prepare(_ url: URL, generation token: Int, attempt: Int) {
        guard token == generation, desiredPaths.contains(url.path), !pendingPaths.contains(url.path) else { return }
        guard let groupID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == Self.identifier(groupID),
              bundle.object(forInfoDictionaryKey: "DockFoldersGroupID") as? String == groupID.uuidString,
              bundle.object(forInfoDictionaryKey: "DockFoldersEntryProtocol") as? Int == 2,
              bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true else {
            preparationFailures[url.path] = "分组代理身份或协议不匹配，未预热。"
            return
        }
        if let running = Self.ownedApplications(dataDirectory: dataDirectory).first(where: {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url
        }) {
            if running.activationPolicy == .accessory { return }
            // 兼容升级前的一次性 regular 代理；只向确认为本项目所有的进程请求正常退出。
            guard attempt < 15 else {
                preparationFailures[url.path] = "旧分组代理仍在退出，未重复启动。"
                return
            }
            _ = running.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.prepare(url, generation: token, attempt: attempt + 1)
            }
            return
        }
        pendingPaths.insert(url.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        guard let ownerStart = NSRunningApplication.current.launchDate?.timeIntervalSince1970 else {
            pendingPaths.remove(url.path)
            preparationFailures[url.path] = "无法核验主工具实例身份，未预热。"
            return
        }
        configuration.arguments = ["--dockfolders-prepare", "--dockfolders-owner-pid", String(ProcessInfo.processInfo.processIdentifier),
                                   "--dockfolders-owner-start", String(ownerStart)]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] opened, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { opened?.terminate(); return }
                if !self.desiredPaths.contains(url.path) { opened?.terminate(); return }
                self.pendingPaths.remove(url.path)
                if let message { self.preparationFailures[url.path] = message }
            }
        }
    }

    private static func identifier(_ id: UUID) -> String { "local.dockfolders.group." + id.uuidString.lowercased() }

    private static func ownedApplications(dataDirectory: URL) -> [NSRunningApplication] {
        let entries = dataDirectory.appendingPathComponent("Entries", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, let url = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath(),
                  url.deletingLastPathComponent() == entries, url.pathExtension == "app",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return false }
            return app.bundleIdentifier == identifier(id)
        }
    }
}
