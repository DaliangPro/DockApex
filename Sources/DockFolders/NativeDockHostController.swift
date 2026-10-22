import AppKit
import ApplicationServices

/// 原生承载只改分组对应的固定项；所有普通图标、系统占位、HUD 和窗口动画均属于系统 Dock。
@MainActor
final class NativeDockHostController {
    private let integration: DockIntegration
    private let builder: GroupEntryBuilder
    private let dataDirectory: URL
    private let entriesDirectory: URL
    private let onMerge: (String, String) -> Void
    private let onStatus: (String) -> Void
    private let onItemsChanged: () -> Void
    private var groups: [AppGroup] = []
    private var cachedSnapshot: DockAccessibilitySnapshot?
    private var state: NativeDockHostState?
    private var pinnedPaths: [String] = []
    private var observedApplicationPaths: [String] = []
    private var lastSnapshotRawPaths: [String] = []
    private var lastSnapshotWasComplete = false
    private var lastCombinedPaths: [String] = []
    private var normalizedPathCache: [String: String] = [:]
    private var referenceCache = NativeDockApplicationReferenceCache()
    private(set) var applicationReferences: [AppReference] = []
    private let preview = NativeDockMergePreview()
    private lazy var gestures = DockGestureController(onGroup: { [weak self] source, target, _ in
        guard let self, let sourceID = self.itemID(for: source), let targetID = self.itemID(for: target), sourceID != targetID else { return }
        self.onMerge(sourceID, targetID)
    }, onHover: { [weak self] message, point in
        self?.preview.show(message, atQuartzPoint: point)
    }, onStatus: { [weak self] message in self?.onStatus(message) },
       diagnosticsDirectory: dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true))

    init(dataDirectory: URL, mainAppURL: URL, proxyExecutable: URL,
         onMerge: @escaping (String, String) -> Void,
         onStatus: @escaping (String) -> Void,
         onItemsChanged: @escaping () -> Void = {}) throws {
        self.dataDirectory = dataDirectory
        entriesDirectory = dataDirectory.appendingPathComponent("Entries", isDirectory: true)
        integration = try DockIntegration(backupsDirectory: dataDirectory.appendingPathComponent("Backups", isDirectory: true))
        builder = GroupEntryBuilder(entriesDirectory: entriesDirectory, proxyExecutable: proxyExecutable, mainAppURL: mainAppURL)
        self.onMerge = onMerge
        self.onStatus = onStatus
        self.onItemsChanged = onItemsChanged
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let loaded = try NativeDockHostState.load(stateURL)
            let expectedPaths = Set(loaded.migratedIDs.compactMap { UUID(uuidString: $0) }.map {
                DockLayout.normalizedPath(entriesDirectory.appendingPathComponent($0.uuidString + ".app"))
            })
            guard loaded.entryPaths.isSubset(of: expectedPaths),
                  loaded.removedTiles.allSatisfy({ path, tile in DockLayout.appURL(in: tile).map(DockLayout.normalizedPath) == path }),
                  Set(loaded.entryMembers.keys).isSubset(of: loaded.entryPaths) else {
                throw DockFoldersError.message("原生分组恢复记录身份不完整，已停止修改 Dock。")
            }
            let recovered = try loaded.resolvingPending(current: integration.fixedItems())
            let recoveredPaths = Set(recovered.migratedIDs.compactMap { UUID(uuidString: $0) }.map {
                DockLayout.normalizedPath(entriesDirectory.appendingPathComponent($0.uuidString + ".app"))
            })
            guard recovered.entryPaths.isSubset(of: recoveredPaths),
                  recovered.removedTiles.allSatisfy({ path, tile in DockLayout.appURL(in: tile).map(DockLayout.normalizedPath) == path }),
                  Set(recovered.entryMembers.keys).isSubset(of: recovered.entryPaths) else {
                throw DockFoldersError.message("原生分组待提交恢复身份不完整，未修改布局。")
            }
            if loaded.pending != nil { try recovered.save(stateURL) }
            state = recovered
        }
    }

    private var stateURL: URL { dataDirectory.appendingPathComponent("native-host-session.plist") }
    var orientation: DockPosition {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let value = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        return DockPosition(rawValue: value ?? "bottom") ?? .bottom
    }
    func entryURL(groupID: UUID) -> URL { entriesDirectory.appendingPathComponent(groupID.uuidString + ".app", isDirectory: true) }

    /// 第一次迁移才补入口；用户后来从原生 Dock 移走的分组不会被定时重钉。
    func install(groups: [AppGroup]) throws {
        var before = try integration.fixedItems()
        if let state, state.active, DockLayout.identities(before) != DockLayout.identities(state.lastApplied),
           try integration.repairUnpersistedCommit(expectedAfter: state.lastApplied) {
            before = try integration.fixedItems()
            onStatus("已补回上次被系统 Dock 旧内存覆盖的分组，新的原生进程已核对。")
        }
        pinnedPaths = before.compactMap { DockLayout.appURL(in: $0).map { normalizedPath($0) } }
        if state == nil || state?.active != true {
            let original = NativeDockHostState(before: before)
            let permanentBackup = dataDirectory.appendingPathComponent("Backups/native-host-original.plist")
            if !FileManager.default.fileExists(atPath: permanentBackup.path) { try original.save(permanentBackup) }
            state = original
        }
        try applyGroups(from: self.groups, to: groups, before: before, installation: true)
    }

    func updateGroups(from old: [AppGroup], to new: [AppGroup]) throws {
        try applyGroups(from: old, to: new, before: integration.fixedItems(), installation: false)
    }

    private func applyGroups(from old: [AppGroup], to new: [AppGroup], before: [[String: Any]], installation: Bool) throws {
        var nextState = state ?? NativeDockHostState(before: before)
        if DockLayout.identities(before) != DockLayout.identities(nextState.lastApplied) { nextState.sawExternalChanges = true }
        var after = before
        let newIDs = Set(new.map(\.id))
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newMembers = Set(new.flatMap(\.apps).map(\.path))
        // 删除分组时只展开这个入口；其它原生排序和未知 tile 保持原样。
        for removed in old where !newIDs.contains(removed.id) {
            let path = DockLayout.normalizedPath(entryURL(groupID: removed.id))
            if let index = after.firstIndex(where: { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) == path }) {
                after.remove(at: index)
                let existing = Set(after.compactMap { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) })
                let restored = removed.apps.filter { !newMembers.contains($0.path) && !existing.contains($0.path) }.map { app in
                    nextState.removedTiles[app.path] ?? DockLayout.newTile(url: app.appURL, label: app.name, bundleIdentifier: app.bundleIdentifier)
                }
                after.insert(contentsOf: restored, at: index)
            }
        }
        after = NativeDockHostLayout.releasingMembers(from: old, to: new, tiles: after,
            removedTiles: nextState.removedTiles, entryURL: { entryURL(groupID: $0) })
        for group in new {
            let entry = entryURL(groupID: group.id)
            let path = DockLayout.normalizedPath(entry)
            let prior = oldByID[group.id]
            let tracked = nextState.migratedIDs.contains(group.id.uuidString)
            let existingIndex = after.firstIndex { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) == path }
            let changed = prior != group
            let shouldInstall = existingIndex == nil && (!tracked || (!installation && prior == nil))
            // 新进程首次看到已迁移入口时刷新资源，不改它的顺序；无变化不重复签名。
            if changed || !FileManager.default.fileExists(atPath: entry.path) { _ = try builder.build(group: group) }
            if let existingIndex, changed {
                after[existingIndex] = DockIntegration.renamedTile(after[existingIndex], label: group.name)
            }
            let priorMembers = Set(prior?.apps.map(\.path) ?? [])
            let addedMembers = Set(group.apps.map(\.path)).subtracting(tracked && prior != nil ? priorMembers : [])
            // 重启时不能重新删除用户后来独立钉住的成员；只处理首次迁移或本次新增成员。
            let membersToRemove = installation && tracked ? Set<String>() : addedMembers
            let memberIndices = after.indices.filter { index in
                DockLayout.appURL(in: after[index]).map(DockLayout.normalizedPath).map(membersToRemove.contains) == true
            }
            for index in memberIndices {
                if let appPath = DockLayout.appURL(in: after[index]).map(DockLayout.normalizedPath), nextState.removedTiles[appPath] == nil {
                    nextState.removedTiles[appPath] = after[index]
                }
            }
            if shouldInstall {
                let tile = DockLayout.newTile(url: entry, label: group.name, bundleIdentifier: Bundle(url: entry)?.bundleIdentifier)
                let preferred = group.apps.first?.path
                let anchor = after.firstIndex { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) == preferred }
                    ?? memberIndices.first ?? after.endIndex
                after.insert(tile, at: anchor)
            }
            if !membersToRemove.isEmpty {
                after.removeAll { tile in DockLayout.appURL(in: tile).map(DockLayout.normalizedPath).map(membersToRemove.contains) == true }
            }
            nextState.migratedIDs.insert(group.id.uuidString)
            nextState.entryPaths.insert(path)
            let retained = nextState.entryMembers[path] ?? []
            let added = group.apps.map(\.path).filter { nextState.removedTiles[$0] != nil && !retained.contains($0) }
            nextState.entryMembers[path] = retained + added
        }
        nextState.lastApplied = after
        nextState.active = true
        try commitStateTransition(before: before, after: after, priorGroups: old, next: nextState)
        groups = new
        pinnedPaths = after.compactMap { DockLayout.appURL(in: $0).map { normalizedPath($0) } }
        updateApplications()
    }

    private func commitStateTransition(before: [[String: Any]], after: [[String: Any]], priorGroups: [AppGroup], next: NativeDockHostState) throws {
        let previous = state ?? NativeDockHostState(before: before)
        var pending = next
        pending.pending = NativeDockHostPending(before: before, after: after, previous: try previous.encoded())
        // 崩溃时能判定 native 写入发生在前还是后，不能将未执行迁移记成用户主动移除。
        try pending.save(stateURL)
        do { _ = try integration.apply(before: before, after: after, priorGroups: priorGroups) }
        catch {
            try? previous.save(stateURL)
            state = previous
            throw error
        }
        state = next
        try next.save(stateURL)
    }

    /// 仅由“恢复原 Dock 并退出”调用。普通退出保留分组，入口可再次启动主应用。
    func restoreOriginalIfUnchanged() throws {
        guard var state, state.active else { return }
        let current = try integration.fixedItems()
        let presentOwned = Set(current.compactMap { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) }).intersection(state.entryPaths)
        guard presentOwned.allSatisfy({ state.entryMembers[$0] != nil }) else {
            throw DockFoldersError.message("分组原始成员记录不完整，为保留当前 Dock，本次没有恢复或覆盖。")
        }
        let restored = NativeDockHostLayout.restoring(current: current, baseline: state.before,
            expected: state.lastApplied, ownedEntryPaths: state.entryPaths,
            removedTiles: state.removedTiles, entryMembers: state.entryMembers, sawExternalChanges: state.sawExternalChanges)
        state.active = false
        state.lastApplied = restored
        try commitStateTransition(before: current, after: restored, priorGroups: groups, next: state)
        pinnedPaths = restored.compactMap { DockLayout.appURL(in: $0).map { normalizedPath($0) } }
        updateApplications()
    }

    func start() {
        gestures.onSnapshot = { [weak self] snapshot in
            self?.recordSnapshot(snapshot)
        }
        _ = gestures.start()
    }
    func stop() { gestures.stop(); preview.show(nil, atQuartzPoint: .zero) }
    private func normalizedPath(_ url: URL) -> String {
        let raw = url.path
        if let cached = normalizedPathCache[raw] { return cached }
        let result = DockLayout.normalizedPath(url)
        normalizedPathCache[raw] = result
        return result
    }

    private func recordSnapshot(_ snapshot: DockAccessibilitySnapshot) {
        cachedSnapshot = snapshot
        let paths = snapshot.items.map { $0.appURL.path }
        // 几何每次更新；路径完全相同时不读偏好、不解析 Bundle，也不触发 UI refresh。
        guard paths != lastSnapshotRawPaths || snapshot.isComplete != lastSnapshotWasComplete else { return }
        lastSnapshotRawPaths = paths
        lastSnapshotWasComplete = snapshot.isComplete
        let canonical = snapshot.items.map { normalizedPath($0.appURL) }
        if snapshot.isComplete {
            observedApplicationPaths = canonical
        } else {
            var seen = Set(observedApplicationPaths)
            observedApplicationPaths.append(contentsOf: canonical.filter { seen.insert($0).inserted })
        }
        updateApplications()
    }

    private func updateApplications() {
        var seen = Set<String>()
        let paths = (pinnedPaths + observedApplicationPaths).filter { seen.insert($0).inserted && !$0.hasPrefix(entriesDirectory.path + "/") }
        guard paths != lastCombinedPaths else { return }
        lastCombinedPaths = paths
        let previous = applicationReferences
        applicationReferences = paths.compactMap { referenceCache.reference(path: $0) }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        if applicationReferences != previous { onItemsChanged() }
    }

    /// 缓存供同步菜单定位；URL 打开应用时应先等待 refreshEntryRect，避免主线程 AX 阻塞。
    func entryRect(groupID: UUID) -> CGRect? {
        let path = DockLayout.normalizedPath(entryURL(groupID: groupID))
        guard let frame = cachedSnapshot?.items.first(where: { DockLayout.normalizedPath($0.appURL) == path })?.frame else { return nil }
        return appKitRect(frame)
    }
    func refreshEntryRect(groupID: UUID) async -> CGRect? {
        guard let pid = DockAccessibility.dockProcessID else { return entryRect(groupID: groupID) }
        let url = entryURL(groupID: groupID)
        let result = await Task.detached(priority: .userInitiated) {
            DockAccessibility.applicationItem(url: url, processID: pid)
        }.value
        guard let result else { return nil }
        if var snapshot = cachedSnapshot, snapshot.processID == pid {
            snapshot = DockAccessibilitySnapshot(processID: pid,
                items: snapshot.items.filter { $0.appURL != result.appURL } + [result],
                visitedElementCount: snapshot.visitedElementCount, isComplete: snapshot.isComplete)
            cachedSnapshot = snapshot
        } else {
            cachedSnapshot = DockAccessibilitySnapshot(processID: pid, items: [result], visitedElementCount: 1, isComplete: false)
        }
        return appKitRect(result.frame)
    }
    private func appKitRect(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
    private func itemID(for url: URL) -> String? {
        let path = normalizedPath(url)
        if let group = groups.first(where: { entryURL(groupID: $0.id).path == path }) { return "group:" + group.id.uuidString }
        guard !path.hasPrefix(entriesDirectory.path + "/"), let app = referenceCache.reference(path: path), app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return "app:" + app.path
    }
}

/// 保留期间发生原生编辑时，只逆转本工具拥有的入口，不能拿旧 shelf 整体覆盖。
enum NativeDockHostLayout {
    /// “移出分组，放回应用栏”是用户主动固定操作，不能仅改 shelf.json。
    /// 仅运行成员在此操作中会新建固定项；恢复原 Dock 的路径仍只还原历史固定项。
    static func releasingMembers(from old: [AppGroup], to new: [AppGroup], tiles: [[String: Any]],
                                 removedTiles: [String: [String: Any]], entryURL: (UUID) -> URL) -> [[String: Any]] {
        var result = tiles
        let retainedIDs = Set(new.map(\.id))
        let allNewMembers = Set(new.flatMap(\.apps).map(\.path))
        var present = Set(tiles.compactMap { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) })
        for group in old where retainedIDs.contains(group.id) {
            let released = group.apps.filter { !allNewMembers.contains($0.path) && !present.contains($0.path) }
            guard !released.isEmpty else { continue }
            let entryPath = DockLayout.normalizedPath(entryURL(group.id))
            let insertion = result.firstIndex(where: { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) == entryPath }).map { $0 + 1 } ?? result.endIndex
            let inserted = released.map { app in
                present.insert(app.path)
                return removedTiles[app.path] ?? DockLayout.newTile(url: app.appURL, label: app.name, bundleIdentifier: app.bundleIdentifier)
            }
            result.insert(contentsOf: inserted, at: insertion)
        }
        return result
    }

    static func restoring(current: [[String: Any]], baseline: [[String: Any]], expected: [[String: Any]],
                          ownedEntryPaths: Set<String>, removedTiles: [String: [String: Any]],
                          entryMembers: [String: [String]], sawExternalChanges: Bool) -> [[String: Any]] {
        if !sawExternalChanges && DockLayout.identities(current) == DockLayout.identities(expected) {
            // 原生会补写 bookmark、日期及未知字段；恢复顺序时保留仍存在项的最新元数据。
            var available = current
            return baseline.map { tile in
                let identity = DockLayout.identities([tile])[0]
                guard let index = available.firstIndex(where: { DockLayout.identities([$0])[0] == identity }) else { return tile }
                return available.remove(at: index)
            }
        }
        var present = Set(current.compactMap { DockLayout.appURL(in: $0).map(DockLayout.normalizedPath) })
        var output: [[String: Any]] = []
        for tile in current {
            guard let path = DockLayout.appURL(in: tile).map(DockLayout.normalizedPath), ownedEntryPaths.contains(path) else {
                output.append(tile); continue
            }
            present.remove(path)
            let members = entryMembers[path] ?? []
            for member in members where !present.contains(member) {
                if let original = removedTiles[member] { output.append(original); present.insert(member)  }
            }
        }
        return output
    }
}

struct NativeDockHostPending {
    let before: [[String: Any]]
    let after: [[String: Any]]
    let previous: Data
}

enum NativeDockHostPendingResolution: Equatable { case notApplied, applied, ambiguous }

enum NativeDockHostTransactionRules {
    static func resolve(current: [[String: Any]], before: [[String: Any]], after: [[String: Any]]) -> NativeDockHostPendingResolution {
        if DockLayout.identities(current) == DockLayout.identities(after) { return .applied }
        if DockLayout.identities(current) == DockLayout.identities(before) { return .notApplied }
        return .ambiguous
    }
}

/// Bundle 元数据仅对新路径构造一次；包括失败路径，避免坏入口反复耗时。
@MainActor
struct NativeDockApplicationReferenceCache {
    private var references: [String: AppReference] = [:]
    private var failures = Set<String>()
    mutating func reference(path: String, make: (URL) -> AppReference? = AppReference.init(url:)) -> AppReference? {
        if let reference = references[path] { return reference }
        guard !failures.contains(path) else { return nil }
        if let reference = make(URL(fileURLWithPath: path)) { references[path] = reference; return reference }
        failures.insert(path)
        return nil
    }
}

struct NativeDockHostState {
    var before: [[String: Any]]
    var lastApplied: [[String: Any]]
    var migratedIDs = Set<String>()
    var entryPaths = Set<String>()
    var removedTiles: [String: [String: Any]] = [:]
    var entryMembers: [String: [String]] = [:]
    var sawExternalChanges = false
    var active = true
    var pending: NativeDockHostPending?
    init(before: [[String: Any]]) { self.before = before; lastApplied = before }
    func save(_ url: URL) throws { try encoded().write(to: url, options: .atomic) }
    func encoded() throws -> Data {
        var value: [String: Any] = ["version": 1, "before": before, "lastApplied": lastApplied,
            "migratedIDs": Array(migratedIDs).sorted(), "entryPaths": Array(entryPaths).sorted(),
            "removedTiles": removedTiles, "entryMembers": entryMembers, "sawExternalChanges": sawExternalChanges, "active": active]
        if let pending { value["pending"] = ["before": pending.before, "after": pending.after, "previous": pending.previous] }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    static func load(_ url: URL) throws -> Self { try decode(Data(contentsOf: url)) }
    static func decode(_ data: Data) throws -> Self {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["version"] as? Int == 1,
              let before = value["before"] as? [[String: Any]], let last = value["lastApplied"] as? [[String: Any]],
              let migrated = value["migratedIDs"] as? [String], let entries = value["entryPaths"] as? [String],
              let removed = value["removedTiles"] as? [String: [String: Any]],
              let members = value["entryMembers"] as? [String: [String]],
              let external = value["sawExternalChanges"] as? Bool, let active = value["active"] as? Bool else {
            throw DockFoldersError.message("原生 Dock 承载备份格式不完整，已停止布局修改；请保留 Data/native-host-session.plist 排查。")
        }
        var result = Self(before: before)
        result.lastApplied = last; result.migratedIDs = Set(migrated); result.entryPaths = Set(entries)
        result.removedTiles = removed; result.entryMembers = members; result.sawExternalChanges = external; result.active = active
        if let pending = value["pending"] as? [String: Any] {
            guard let before = pending["before"] as? [[String: Any]], let after = pending["after"] as? [[String: Any]],
                  let previous = pending["previous"] as? Data else { throw DockFoldersError.message("原生 Dock 待提交记录不完整，未修改布局。") }
            result.pending = NativeDockHostPending(before: before, after: after, previous: previous)
        } else if value["pending"] != nil { throw DockFoldersError.message("原生 Dock 待提交记录格式错误，未修改布局。") }
        return result
    }
    func resolvingPending(current: [[String: Any]]) throws -> Self {
        guard let pending else { return self }
        switch NativeDockHostTransactionRules.resolve(current: current, before: pending.before, after: pending.after) {
        case .applied:
            var committed = self
            committed.pending = nil
            return committed
        case .notApplied:
            let previous = try Self.decode(pending.previous)
            guard previous.pending == nil else { throw DockFoldersError.message("原生 Dock 待提交记录嵌套异常，未覆盖当前布局。") }
            return previous
        case .ambiguous:
            throw DockFoldersError.message("上次分组提交中断，随后原生 Dock 又发生变化。为保留当前排序，本次未覆盖；恢复记录在 Data/native-host-session.plist。")
        }
    }
}

/// 不激活、不接收鼠标的轻量提示；鼠标从始至终仍落在原生 Dock 上。
@MainActor
private final class NativeDockMergePreview {
    private var panel: NSPanel?
    private var label: NSTextField?
    func show(_ message: String?, atQuartzPoint point: CGPoint) {
        guard let message else { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            // 原生拖动图像在 dragging 层；提示置于其上一层，仍完全穿透鼠标。
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let background = NSVisualEffectView()
            background.material = .popover; background.state = .active; background.wantsLayer = true
            background.layer?.cornerRadius = 10; background.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            background.addSubview(label); panel.contentView = background
            self.panel = panel; self.label = label
        }
        guard let panel, let label else { return }
        label.stringValue = message; label.sizeToFit()
        let size = CGSize(width: label.frame.width + 22, height: 32)
        label.setFrameOrigin(CGPoint(x: 11, y: 9))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let appPoint = CGPoint(x: point.x, y: top - point.y)
        let visible = NSScreen.screens.first(where: { $0.frame.contains(appPoint) })?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let x = min(max(appPoint.x - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        let y = min(max(appPoint.y + 36, visible.minY + 6), visible.maxY - size.height - 6)
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: false)
        panel.orderFrontRegardless()
    }
}
