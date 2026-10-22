import AppKit

/// 仅计算布局，不读写用户 Dock、不注册输入观察。
@main
struct NativeDockHostChecks {
    @MainActor static func main() throws {
        func tile(_ name: String) -> [String: Any] {
            DockLayout.newTile(url: URL(fileURLWithPath: "/Applications/\(name).app"), label: name, bundleIdentifier: "example.\(name)")
        }
        func path(_ tile: [String: Any]) -> String { DockLayout.normalizedPath(DockLayout.appURL(in: tile)!) }
        func names(_ tiles: [[String: Any]]) -> [String] { tiles.compactMap(DockLayout.appURL(in:)).map { $0.deletingPathExtension().lastPathComponent } }
        let a = tile("A"), b = tile("B"), c = tile("C"), x = tile("X"), g = tile("G"), h = tile("H")
        let originals = [path(a): a, path(b): b]
        let groupMap = [path(g): [path(a), path(b)]]
        func restore(_ current: [[String: Any]], external: Bool = false) -> [[String: Any]] {
            NativeDockHostLayout.restoring(current: current, baseline: [a,b,c], expected: [g,c],
                ownedEntryPaths: [path(g)], removedTiles: originals, entryMembers: groupMap, sawExternalChanges: external)
        }
        precondition(names(restore([g,c])) == ["A","B","C"])
        precondition(names(restore([c,g])) == ["C","A","B"])
        precondition(names(restore([x,g,c])) == ["X","A","B","C"])
        precondition(names(restore([c,x])) == ["C","X"])
        precondition(names(restore([c,g,a])) == ["C","B","A"])
        var newC = c
        var data = newC["tile-data"] as! [String: Any]
        data["unknown-dock-field"] = ["retain": true]
        newC["tile-data"] = data
        let metadata = restore([g,newC]).last!
        precondition(NSDictionary(dictionary: metadata).isEqual(to: newC))
        let spacer: [String: Any] = ["GUID": 42, "tile-type": "spacer-tile", "tile-data": ["future": 9]]
        precondition(NSDictionary(dictionary: restore([g,spacer,c])[2]).isEqual(to: spacer))
        let two = NativeDockHostLayout.restoring(current: [h,x,g], baseline: [a,b,c], expected: [g,h],
            ownedEntryPaths: [path(g),path(h)], removedTiles: [path(a):a,path(b):b,path(c):c],
            entryMembers: [path(g):[path(a),path(b)],path(h):[path(c)]], sawExternalChanges: false)
        precondition(names(two) == ["C","X","A","B"])
        // 已确认期间发生过外部变化时，即使最后身份序列恰好相同，也按当前分组位置展开。
        precondition(names(restore([g,c], external: true)) == ["A","B","C"])
        let renamed = DockIntegration.renamedTile(newC, label: "新名字")
        let renamedData = renamed["tile-data"] as! [String: Any]
        precondition(renamedData["file-label"] as? String == "新名字")
        precondition(renamedData["unknown-dock-field"] != nil && renamed["GUID"] as? UInt32 == newC["GUID"] as? UInt32)
        // 持久化提交前/后的崩溃边界：只编码内存数据，不触碰真实 Dock 或磁盘配置。
        let prior = NativeDockHostState(before: [a,b,c])
        var next = prior
        next.lastApplied = [g,c]
        next.migratedIDs = ["group"]
        next.entryPaths = [path(g)]
        next.removedTiles = originals
        next.entryMembers = groupMap
        next.pending = NativeDockHostPending(before: [a,b,c], after: [g,c], previous: try prior.encoded())
        let pending = try NativeDockHostState.decode(next.encoded())
        let notWritten = try pending.resolvingPending(current: [a,b,c])
        precondition(notWritten.migratedIDs.isEmpty && notWritten.pending == nil)
        let written = try pending.resolvingPending(current: [g,c])
        precondition(written.migratedIDs == ["group"] && written.pending == nil && written.entryMembers == groupMap)
        var refused = false
        do { _ = try pending.resolvingPending(current: [x,g,c]) } catch { refused = true }
        precondition(refused)
        precondition(NativeDockHostTransactionRules.resolve(current: [newC], before: [c], after: [c]) == .applied)
        let legacyState = try NativeDockHostState.decode(prior.encoded())
        precondition(legacyState.pending == nil)
        var restoring = written
        restoring.active = false
        restoring.lastApplied = [a,b,c]
        restoring.pending = NativeDockHostPending(before: [g,c], after: [a,b,c], previous: try written.encoded())
        let restoredAfterCrash = try restoring.resolvingPending(current: [a,b,c])
        let notRestoredAfterCrash = try restoring.resolvingPending(current: [g,c])
        precondition(restoredAfterCrash.active == false)
        precondition(notRestoredAfterCrash.active == true)
        var malformed = try PropertyListSerialization.propertyList(from: prior.encoded(), format: nil) as! [String: Any]
        malformed["pending"] = "broken"
        var invalidRefused = false
        do { _ = try NativeDockHostState.decode(PropertyListSerialization.data(fromPropertyList: malformed, format: .binary, options: 0)) }
        catch { invalidRefused = true }
        precondition(invalidRefused)

        var cache = NativeDockApplicationReferenceCache()
        var made = 0
        let factory: (URL) -> AppReference? = { url in
            made += 1
            return AppReference(path: url.path, name: "缓存测试", bundleIdentifier: "example.cache")
        }
        let firstReference = cache.reference(path: path(a), make: factory)
        precondition(cache.reference(path: path(a), make: factory) == firstReference && made == 1)
        _ = cache.reference(path: path(b), make: factory)
        precondition(made == 2)
        var failures = 0
        let failedFactory: (URL) -> AppReference? = { _ in failures += 1; return nil }
        precondition(cache.reference(path: "/Missing.app", make: failedFactory) == nil)
        precondition(cache.reference(path: "/Missing.app", make: failedFactory) == nil && failures == 1)
        // 仅运行成员没有 removedTiles，恢复时不会意外变成固定图标。
        let runtimeOnly = NativeDockHostLayout.restoring(current: [x,g,c], baseline: [a,b,c], expected: [g,c],
            ownedEntryPaths: [path(g),path(h)], removedTiles: originals,
            entryMembers: [path(g):[path(a),path(b)],path(h):[]], sawExternalChanges: true)
        precondition(names(runtimeOnly) == ["X","A","B","C"])
        let groupID = UUID(), otherGroupID = UUID()
        func reference(_ tile: [String: Any]) -> AppReference {
            AppReference(path: path(tile), name: "离组测试", bundleIdentifier: "example.release")
        }
        let oldGroup = AppGroup(id: groupID, name: "G", apps: [reference(a),reference(b)])
        let retainedGroup = AppGroup(id: groupID, name: "G", apps: [reference(b)])
        let entry: (UUID) -> URL = { $0 == groupID ? DockLayout.appURL(in: g)! : DockLayout.appURL(in: h)! }
        var originalA = a
        var originalData = originalA["tile-data"] as! [String: Any]
        originalData["retained-field"] = "original-metadata"
        originalA["tile-data"] = originalData
        let released = NativeDockHostLayout.releasingMembers(from: [oldGroup], to: [retainedGroup], tiles: [g,c],
            removedTiles: [path(a):originalA], entryURL: entry)
        precondition(names(released) == ["G","A","C"])
        precondition(NSDictionary(dictionary: released[1]).isEqual(to: originalA))
        let runtimeReleased = NativeDockHostLayout.releasingMembers(from: [oldGroup], to: [retainedGroup], tiles: [g,c],
            removedTiles: [:], entryURL: entry)
        precondition(names(runtimeReleased) == ["G","A","C"])
        let independentlyPinned = NativeDockHostLayout.releasingMembers(from: [oldGroup], to: [retainedGroup], tiles: [a,g,c],
            removedTiles: originals, entryURL: entry)
        precondition(names(independentlyPinned) == ["A","G","C"])
        let movedGroup = AppGroup(id: otherGroupID, name: "H", apps: [reference(a)])
        let transferred = NativeDockHostLayout.releasingMembers(from: [oldGroup], to: [retainedGroup,movedGroup], tiles: [g,h,c],
            removedTiles: originals, entryURL: entry)
        precondition(names(transferred) == ["G","H","C"])
        let missingEntry = NativeDockHostLayout.releasingMembers(from: [oldGroup], to: [retainedGroup], tiles: [c],
            removedTiles: originals, entryURL: entry)
        precondition(names(missingEntry) == ["C","A"])
        let unchanged = NativeDockHostLayout.releasingMembers(from: [oldGroup], to: [oldGroup], tiles: [g,c],
            removedTiles: originals, entryURL: entry)
        precondition(names(unchanged) == ["G","C"])
        precondition(DockLayoutCommitRules.isExactRevertedTransaction(current: [a,b,c], before: [a,b,c], after: [g,c], expectedAfter: [g,c]))
        precondition(!DockLayoutCommitRules.isExactRevertedTransaction(current: [a,b,newC], before: [a,b,c], after: [g,c], expectedAfter: [g,c]))
        precondition(!DockLayoutCommitRules.isExactRevertedTransaction(current: [g,c], before: [a,b,c], after: [g,c], expectedAfter: [g,c]))
        precondition(!DockLayoutCommitRules.isExactRevertedTransaction(current: [a,b,c], before: [a,b,c], after: [g,c], expectedAfter: [h,c]))
        precondition(!DockLayoutCommitRules.isExactRevertedTransaction(current: [a,b,c], before: [a,b,c], after: [a,b,c], expectedAfter: [a,b,c]))
        precondition(!DockLayoutCommitRules.isExactRevertedTransaction(current: [a,b,c], before: [a,b,c], after: [g,c], expectedAfter: [g,c], nativePersistenceVerified: true))
        var stable = DockLayoutStableVerification()
        precondition(!stable.observe(isReplacement: false, identitiesMatch: true))
        precondition(!stable.observe(isReplacement: true, identitiesMatch: true))
        precondition(!stable.observe(isReplacement: true, identitiesMatch: false))
        precondition(!stable.observe(isReplacement: true, identitiesMatch: true))
        precondition(!stable.observe(isReplacement: true, identitiesMatch: true))
        precondition(stable.observe(isReplacement: true, identitiesMatch: true))
        var count = 43
        func additional(_ condition: @autoclosure () -> Bool) { precondition(condition()); count += 1 }
        let entriesDirectory = URL(fileURLWithPath: "/测试/Data/Entries", isDirectory: true)
        let ownedID = UUID(), newOwnedID = UUID()
        let owned = DockLayout.newTile(url: entriesDirectory.appendingPathComponent(ownedID.uuidString + ".app"),
            label: "旧组", bundleIdentifier: "local.dockfolders.group." + ownedID.uuidString.lowercased())
        let newOwned = DockLayout.newTile(url: entriesDirectory.appendingPathComponent(newOwnedID.uuidString + ".app"),
            label: "新组", bundleIdentifier: "local.dockfolders.group." + newOwnedID.uuidString.lowercased())
        var rewrittenOwned = DockIntegration.renamedTile(owned, label: ownedID.uuidString)
        var rewrittenData = rewrittenOwned["tile-data"] as! [String: Any]
        rewrittenData["file-mod-date"] = 12345; rewrittenData["parent-mod-date"] = 67890
        rewrittenOwned["tile-data"] = rewrittenData
        let archiveBefore = [a,owned,b,c], archiveAfter = [rewrittenOwned,newOwned,c]
        func plan(_ current: [[String: Any]], before: [[String: Any]]? = nil, after: [[String: Any]]? = nil,
                  verified: Bool = false) -> [[String: Any]]? {
            DockLayoutCommitRules.repairPlan(current: current, before: before ?? archiveBefore,
                after: after ?? archiveAfter, expectedAfter: archiveAfter,
                ownedEntriesDirectory: entriesDirectory, nativePersistenceVerified: verified)
        }
        let allowed = plan([a,rewrittenOwned,b,c])
        additional(allowed != nil)
        additional(NSDictionary(dictionary: allowed![0]).isEqual(to: rewrittenOwned))
        additional(NSDictionary(dictionary: allowed![1]).isEqual(to: newOwned))
        additional(plan([a,rewrittenOwned,b,newC]) == nil)
        var alteredGUID = rewrittenOwned; alteredGUID["GUID"] = 999
        additional(plan([a,alteredGUID,b,c]) == nil)
        var alteredBook = rewrittenOwned
        var alteredData = alteredBook["tile-data"] as! [String: Any]
        alteredData["book"] = Data([1,2,3]); alteredBook["tile-data"] = alteredData
        additional(plan([a,alteredBook,b,c]) == nil)
        var wrongDate = rewrittenOwned
        var wrongDateData = wrongDate["tile-data"] as! [String: Any]
        wrongDateData["file-mod-date"] = "tampered"; wrongDate["tile-data"] = wrongDateData
        additional(plan([a,wrongDate,b,c]) == nil)
        var unknownChange = rewrittenOwned
        var unknownData = unknownChange["tile-data"] as! [String: Any]
        unknownData["unknown-field"] = true; unknownChange["tile-data"] = unknownData
        additional(plan([a,unknownChange,b,c]) == nil)
        var repinnedA = a; repinnedA["GUID"] = 888
        additional(plan([repinnedA,rewrittenOwned,b,c]) == nil)
        additional(plan([b,rewrittenOwned,a,c]) == nil)
        additional(plan([a,rewrittenOwned,b,c,x]) == nil)
        additional(plan([a,b,c]) == nil)
        additional(plan([a,rewrittenOwned,b,c], after: [rewrittenOwned,x,c]) == nil)
        additional(plan([a,rewrittenOwned,b,c], verified: true) == nil)
        additional(plan([a,a,owned,b,c], before: [a,a,owned,b,c]) == nil)
        additional(DockLayoutCommitRules.canRollback(current: [g,newC], written: [g,newC]))
        additional(!DockLayoutCommitRules.canRollback(current: [g,newC], written: [g,c]))
        additional(DockLayoutCommitRules.repairPlan(current: [a,rewrittenOwned,b,c], before: archiveBefore,
            after: [rewrittenOwned,x,c], expectedAfter: [rewrittenOwned,x,c], ownedEntriesDirectory: entriesDirectory) == nil)
        var alteredFileData = rewrittenOwned
        var alteredFileTileData = alteredFileData["tile-data"] as! [String: Any]
        var alteredURLData = alteredFileTileData["file-data"] as! [String: Any]
        alteredURLData["_CFURLStringType"] = 16
        alteredFileTileData["file-data"] = alteredURLData; alteredFileData["tile-data"] = alteredFileTileData
        additional(plan([a,alteredFileData,b,c]) == nil)
        let rebased = DockLayoutCommitRules.rebaseOwnedMetadata(current: [a,rewrittenOwned,b,c], before: archiveBefore,
            desired: [owned,newOwned,c], ownedEntriesDirectory: entriesDirectory)
        additional(rebased != nil && NSDictionary(dictionary: rebased![0]).isEqual(to: rewrittenOwned))
        additional(NSDictionary(dictionary: rebased![1]).isEqual(to: newOwned))
        let intendedRename = DockIntegration.renamedTile(owned, label: "用户改名")
        let rebasedRename = DockLayoutCommitRules.rebaseOwnedMetadata(current: [a,rewrittenOwned,b,c], before: archiveBefore,
            desired: [intendedRename,newOwned,c], ownedEntriesDirectory: entriesDirectory)
        let renamedFields = rebasedRename![0]["tile-data"] as! [String: Any]
        additional(renamedFields["file-label"] as? String == "用户改名" && renamedFields["file-mod-date"] as? Int == 12345)
        additional(DockLayoutCommitRules.rebaseOwnedMetadata(current: [a,rewrittenOwned,b,newC], before: archiveBefore,
            desired: archiveAfter, ownedEntriesDirectory: entriesDirectory) == nil)
        additional(DockLayoutCommitRules.rebaseOwnedMetadata(current: [a,alteredBook,b,c], before: archiveBefore,
            desired: archiveAfter, ownedEntriesDirectory: entriesDirectory) == nil)
        additional(DockLayoutCommitRules.rebaseOwnedMetadata(current: [b,rewrittenOwned,a,c], before: archiveBefore,
            desired: archiveAfter, ownedEntriesDirectory: entriesDirectory) == nil)
        additional(DockLayoutCommitRules.rebaseOwnedMetadata(current: [a,alteredGUID,b,c], before: archiveBefore,
            desired: archiveAfter, ownedEntriesDirectory: entriesDirectory) == nil)
        let echoed = try DockBoundedProcess.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["读取完成"], timeout: 0.8)
        additional(String(data: echoed, encoding: .utf8)?.contains("读取完成") == true)
        let timeoutBegan = ProcessInfo.processInfo.systemUptime
        var timedOut = false
        do { _ = try DockBoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.12) }
        catch { timedOut = true }
        additional(timedOut && ProcessInfo.processInfo.systemUptime - timeoutBegan < 0.8)
        var nonzeroRefused = false
        do { _ = try DockBoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 0.8) }
        catch { nonzeroRefused = true }
        additional(nonzeroRefused)
        if let index = CommandLine.arguments.firstIndex(of: "--inspect-archive"), CommandLine.arguments.indices.contains(index + 2) {
            let archive = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let dataDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
            let transaction = try PropertyListSerialization.propertyList(from: Data(contentsOf: archive.appendingPathComponent("latest.plist")), format: nil) as! [String: Any]
            let archivedState = try NativeDockHostState.load(archive.appendingPathComponent("native-host-session.plist"))
            let exported = try DockBoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/defaults"), arguments: ["export","com.apple.dock","-"], timeout: 0.8)
            let current = (try PropertyListSerialization.propertyList(from: exported, format: nil) as! [String: Any])["persistent-apps"] as! [[String: Any]]
            let result = DockLayoutCommitRules.repairPlan(current: current, before: transaction["before"] as! [[String: Any]],
                after: transaction["after"] as! [[String: Any]], expectedAfter: archivedState.lastApplied,
                ownedEntriesDirectory: dataDirectory.appendingPathComponent("Entries"),
                nativePersistenceVerified: transaction["nativePersistenceVerified"] as? Bool == true)
            print("真实布局只读预检：当前 \(current.count) 项；严格归档补回计划 \(result?.count.description ?? "被拒绝") 项。未执行信号或写入。")
        }
        print("通过 \(count) 项原生承载离线核验：精确恢复、原生排序、新增项、主动移除、重复成员、未知元数据、占位 tile、多分组和改名元数据、提交中断恢复/拒绝覆盖、运行项边界及元数据缓存命中，以及单成员离组/转组/原元数据/已有固定项去重、精确旧事务重放边界和新Dock稳定读回门槛、严格归档补回/元数据保护，以及独立子进程实际超时。未改系统偏好。")
    }
}
