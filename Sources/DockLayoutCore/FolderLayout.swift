import Foundation

enum DockPosition: String, Codable, Sendable { case bottom, left, right }

/// 显示器 UUID 在拔插和重新启动后保持身份，不用临时的 CGDirectDisplayID 存储设置。
enum DockDisplayMode: String, Codable, CaseIterable, Sendable {
    case primary
    case specific
    case followPointer
    case all
}

struct AppReference: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var name: String
    var bundleIdentifier: String?
    var id: String { path }
    var appURL: URL { URL(fileURLWithPath: path) }

    init(path: String, name: String, bundleIdentifier: String?) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    init?(url: URL) {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard normalized.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: normalized) else { return nil }
        path = normalized.path
        name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? normalized.deletingPathExtension().lastPathComponent
        bundleIdentifier = bundle.bundleIdentifier
    }

    /// 启动器：名字相同、路径不同，标识是对方标识加“.后缀”（如 Hermes Setup 的 com.nousresearch.hermes.setup
    /// 拉起 com.nousresearch.hermes）。应用栏把启动器和它拉起的主程序当成同一个 App。
    func launches(_ app: AppReference) -> Bool {
        guard let own = bundleIdentifier, let target = app.bundleIdentifier, path != app.path else { return false }
        return name == app.name && own.hasPrefix(target + ".")
    }
}

/// 应用引用在磁盘变化后的处理：保留、换成新位置或新信息、移除（已卸载）。
enum AppReferenceUpdate: Equatable, Sendable {
    case keep
    case replace(AppReference)
    case remove
}

struct AppGroup: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var apps: [AppReference]
}

struct ShelfFile: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
    var id: String { "file:" + path }
    var url: URL { URL(fileURLWithPath: path) }

    init(url: URL) {
        let url = url.standardizedFileURL
        path = url.path
        name = FileManager.default.displayName(atPath: url.path)
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// 未设置的选项沿用首次启动时读取的本机 Dock 偏好。
struct ShelfOptions: Codable, Equatable, Sendable {
    var iconSize: Double = 37
    var maximumIconSize: Double = 62
    var magnification = true
    var showRunningIndicators = true
    var showRecentApplications = true
    var animateLaunching = true
    var minimizeToApplication: Bool?
    var displayMode: DockDisplayMode?
    var displayUUID: String?
    var reserveWindowSpace: Bool?
}


enum ShelfItem: Codable, Equatable, Identifiable, Sendable {
    case app(AppReference)
    case group(UUID)

    var id: String {
        switch self {
        case .app(let app): "app:" + app.path
        case .group(let id): "group:" + id.uuidString
        }
    }
}

struct ShelfConfiguration: Codable, Equatable, Sendable {
    var version = 1
    var items: [ShelfItem] = []
    var groups: [AppGroup] = []
    var position: DockPosition = .bottom
    var autoHide = false
    var options: ShelfOptions?
    var files: [ShelfFile]?
    var recentApplications: [AppReference]?

    func apps(for id: String) -> [AppReference] {
        guard let item = items.first(where: { $0.id == id }) else { return [] }
        switch item {
        case .app(let app): return [app]
        case .group(let groupID): return groups.first(where: { $0.id == groupID })?.apps ?? []
        }
    }

    mutating func normalize() {
        var groupIDs = Set<UUID>()
        var memberPaths = Set<String>()
        groups = groups.compactMap { group in
            guard groupIDs.insert(group.id).inserted else { return nil }
            var group = group
            group.apps = group.apps.filter { memberPaths.insert($0.path).inserted }
            return group.apps.isEmpty ? nil : group
        }
        let validGroups = Set(groups.map(\.id))
        var itemIDs = Set<String>()
        items = items.filter { item in
            guard itemIDs.insert(item.id).inserted else { return false }
            switch item {
            case .app(let app): return !memberPaths.contains(app.path)
            case .group(let id): return validGroups.contains(id)
            }
        }
        let placed = Set(items.compactMap { item -> UUID? in
            if case .group(let id) = item { return id }; return nil
        })
        for group in groups where !placed.contains(group.id) { items.append(.group(group.id)) }
    }

    /// 两个入口在目标位置变成一个；所有运行状态由展示层计算，不改变成员关系。
    @discardableResult
    mutating func merge(sourceID: String, targetID: String) -> UUID? {
        guard sourceID != targetID,
              let targetIndex = items.firstIndex(where: { $0.id == targetID }),
              items.contains(where: { $0.id == sourceID }) else { return nil }
        let members = apps(for: targetID) + apps(for: sourceID)
        guard !members.isEmpty else { return nil }
        let targetGroup: AppGroup? = if case .group(let id) = items[targetIndex] {
            groups.first(where: { $0.id == id })
        } else { nil }
        let sourceGroupID: UUID? = if case .group(let id) = items.first(where: { $0.id == sourceID }) { id } else { nil }
        let memberPaths = Set(members.map(\.path))
        // 原生 Dock 会额外显示组内运行图标；虚拟提到顶层后，仍须转移真实成员归属。
        // 整组及自身成员、或恰好已组成同一组时保留原组身份和名称。
        if let existing = groups.first(where: { Set($0.apps.map(\.path)) == memberPaths }),
           sourceGroupID == existing.id || targetGroup?.id == existing.id || (sourceGroupID == nil && targetGroup == nil) {
            normalize()
            return existing.id
        }
        let group = AppGroup(id: targetGroup?.id ?? UUID(), name: targetGroup?.name ?? "新分组", apps: members)
        let insertion = items[..<targetIndex].filter { $0.id != sourceID }.count
        items.removeAll { $0.id == sourceID || $0.id == targetID }
        groups.removeAll { $0.id == sourceGroupID || $0.id == targetGroup?.id }
        for index in groups.indices { groups[index].apps.removeAll { memberPaths.contains($0.path) } }
        groups.append(group)
        items.insert(.group(group.id), at: min(insertion, items.count))
        normalize()
        return groups.contains(where: { $0.id == group.id }) ? group.id : nil
    }

    mutating func reorder(id: String, insertionIndex: Int) {
        guard let oldIndex = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: oldIndex)
        let adjusted = insertionIndex - (oldIndex < insertionIndex ? 1 : 0)
        items.insert(item, at: max(0, min(adjusted, items.count)))
    }

    /// 磁盘上的应用变了（卸载、移动、重装）之后，按 resolve 的结论原位替换或移除应用栏、分组与最近使用里的引用，
    /// 再整理掉空分组与重复入口。同一引用只问一次 resolve（同一路径的旧副本可能带着旧包名，要分开问）；
    /// 返回有变化的旧引用及结论。
    @discardableResult
    mutating func updateApplications(_ resolve: (AppReference) -> AppReferenceUpdate) -> [AppReference: AppReferenceUpdate] {
        var decided: [AppReference: AppReferenceUpdate] = [:]
        func updated(_ app: AppReference) -> AppReference? {
            let decision = decided[app] ?? resolve(app)
            decided[app] = decision
            switch decision {
            case .keep: return app
            case .replace(let next): return next
            case .remove: return nil
            }
        }
        items = items.compactMap { item in
            guard case .app(let app) = item else { return item }
            return updated(app).map(ShelfItem.app)
        }
        for index in groups.indices { groups[index].apps = groups[index].apps.compactMap(updated) }
        var recentPaths = Set<String>()
        recentApplications = recentApplications?.compactMap(updated).filter { recentPaths.insert($0.path).inserted }
        normalize()
        return decided.filter { $0.value != .keep }
    }

    mutating func dissolve(_ id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        let index = items.firstIndex(of: .group(id)) ?? items.count
        items.removeAll { $0 == .group(id) }
        groups.removeAll { $0.id == id }
        items.insert(contentsOf: group.apps.map(ShelfItem.app), at: min(index, items.count))
        normalize()
    }
}

/// 自动移除前应用在应用栏或分组里的位置。它很快又装回来时（例如更新程序先删旧包、再放新包）放回这里。
/// 分组记下名字和它在应用栏里的位置：成员都被移除、分组随之消失后，装回来时按原名原位重建。
enum ShelfPlacement: Equatable, Sendable {
    case pinned(index: Int)
    case group(UUID, name: String, slot: Int, index: Int)
}

extension ShelfConfiguration {
    private func contains(_ app: AppReference) -> Bool {
        items.contains { if case .app(let pinned) = $0 { return pinned.path == app.path }; return false }
            || groups.contains { $0.apps.contains { $0.path == app.path } }
    }

    func placement(of app: AppReference) -> ShelfPlacement? {
        if let index = items.firstIndex(where: { if case .app(let pinned) = $0 { return pinned.path == app.path }; return false }) {
            return .pinned(index: index)
        }
        for group in groups {
            guard let index = group.apps.firstIndex(where: { $0.path == app.path }) else { continue }
            let slot = items.firstIndex(of: .group(group.id)) ?? items.count
            return .group(group.id, name: group.name, slot: slot, index: index)
        }
        return nil
    }

    /// 放回原处；已经在应用栏或分组里就不重复放。分组已随成员移除而消失时，按原名原位重建。
    @discardableResult
    mutating func restore(_ app: AppReference, at placement: ShelfPlacement) -> Bool {
        guard !contains(app) else { return false }
        switch placement {
        case .pinned(let index):
            items.insert(.app(app), at: min(index, items.count))
        case .group(let id, let name, let slot, let index):
            if let group = groups.firstIndex(where: { $0.id == id }) {
                groups[group].apps.insert(app, at: min(index, groups[group].apps.count))
            } else {
                groups.append(AppGroup(id: id, name: name, apps: [app]))
                items.insert(.group(id), at: min(slot, items.count))
            }
        }
        normalize()
        return true
    }
}

enum FolderLayout {
    /// 应用所在文件夹的监视是递归的：开发目录里的构建、App 自己写缓存等无关写入也会报上来，每次都要重读几十个
    /// Info.plist、刷新应用栏。只认引用的应用包本身及其内部，和各监视文件夹第一层的 .app（装上、移走、改名）。
    static func relevantApplicationChanges(_ paths: [String], applications: Set<String>, extraFolders: [String]) -> [String] {
        let folders = Set(applications.map { ($0 as NSString).deletingLastPathComponent } + extraFolders)
        return paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { path in
            applications.contains { path == $0 || path.hasPrefix($0 + "/") }
                || (path.hasSuffix(".app") && folders.contains((path as NSString).deletingLastPathComponent))
        }
    }
}
