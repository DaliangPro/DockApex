import AppKit
import Foundation

// 独立 CLI fixture：只在项目 build 下建立可保留的临时目录，不启动 App，
// 不访问 Dock 偏好、辅助功能权限或正式 Data；不删除测试文件。
private enum ShelfStoreCheckError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let text): return text }
    }
}

@main
struct ShelfStoreChecks {
    @MainActor
    static func main() {
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("shelf-store-checks-\(UUID().uuidString)", isDirectory: true)
        var passed = 0
        var failures: [String] = []

        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw ShelfStoreCheckError.failed(message) }
        }

        func configuration() -> ShelfConfiguration {
            let a = AppReference(path: "/Applications/Fixture-A.app", name: "测试 A", bundleIdentifier: "fixture.a")
            let b = AppReference(path: "/Applications/Fixture-B.app", name: "测试 B", bundleIdentifier: "fixture.b")
            let c = AppReference(path: "/Applications/Fixture-C.app", name: "测试 C", bundleIdentifier: "fixture.c")
            return ShelfConfiguration(items: [.app(a), .app(b), .app(c)])
        }

        func changed(_ original: ShelfConfiguration) throws -> ShelfConfiguration {
            var next = original
            guard next.items.count >= 2,
                  next.merge(sourceID: next.items[0].id, targetID: next.items[1].id) != nil else {
                throw ShelfStoreCheckError.failed("fixture 无法建立测试分组")
            }
            return next
        }

        func scenario(_ name: String, _ body: (URL) throws -> Void) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try body(directory)
                passed += 1
                print("通过：\(name)")
            } catch {
                failures.append("\(name)：\(error.localizedDescription)")
                print("失败：\(name)：\(error.localizedDescription)")
            }
        }

        scenario("01-首次保存并重新加载") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(store.configuration, recordUndo: false)
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == initial, "重启后初始配置不一致")
            try expect(reopened.previous == nil, "首次无撤销保存不应生成撤销布局")
        }

        scenario("02-布局与撤销同时持久化") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(initial, recordUndo: false)
            let next = try changed(initial)
            try store.save(next)
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == next, "重启后分组布局丢失")
            try expect(reopened.previous == initial, "重启后撤销布局未对应上次保存")
            let bytes = try Data(contentsOf: directory.appendingPathComponent("shelf.json"))
            let archive = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            try expect(archive?["configuration"] is [String: Any], "未使用同一原子档案保存当前布局")
            try expect(archive?["previous"] is [String: Any], "同一档案缺少撤销布局")
        }

        scenario("03-撤销后重新加载") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(initial, recordUndo: false)
            try store.save(changed(initial))
            try store.undo()
            try expect(store.configuration == initial, "撤销未恢复前一布局")
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == initial, "撤销结果未持久化")
        }

        scenario("04-相同布局保存保留撤销") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(initial, recordUndo: false)
            let next = try changed(initial)
            try store.save(next)
            try store.save(next)
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.previous == initial, "无变更保存覆盖了有效撤销")
        }

        scenario("05-不记录撤销的保存保留原撤销") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(initial, recordUndo: false)
            var next = try changed(initial)
            try store.save(next)
            next.autoHide.toggle()
            try store.save(next, recordUndo: false)
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == next, "无撤销保存没有保存当前配置")
            try expect(reopened.previous == initial, "无撤销保存改变了既有撤销目标")
        }

        scenario("06-保存失败不污染内存与磁盘撤销") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(initial, recordUndo: false)
            try store.save(changed(initial))
            let expectedCurrent = store.configuration
            let expectedPrevious = store.previous
            let file = directory.appendingPathComponent("shelf.json")
            let held = directory.appendingPathComponent("shelf-held.json")
            let blocker = directory.appendingPathComponent("保存失败用目录", isDirectory: true)
            let expectedBytes = try Data(contentsOf: file)

            // 同名目录令原子文件替换失败；原文件和阻塞目录都移入 fixture 保留。
            try files.moveItem(at: file, to: held)
            try files.createDirectory(at: file, withIntermediateDirectories: false)
            var next = expectedCurrent
            next.position = .right
            var didFail = false
            do { try store.save(next) }
            catch { didFail = true }
            try files.moveItem(at: file, to: blocker)
            try files.moveItem(at: held, to: file)

            try expect(didFail, "错误注入没有导致保存失败")
            try expect(store.configuration == expectedCurrent, "失败保存改变了内存当前布局")
            try expect(store.previous == expectedPrevious, "失败保存改变了内存撤销")
            let actualBytes = try Data(contentsOf: file)
            try expect(actualBytes == expectedBytes, "失败保存改变了磁盘原档案")
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == expectedCurrent, "失败后重启当前布局变化")
            try expect(reopened.previous == expectedPrevious, "失败后重启有效撤销丢失")
        }

        scenario("07-兼容旧平铺布局及撤销") { directory in
            let initial = configuration()
            let current = try changed(initial)
            try JSONEncoder().encode(current).write(to: directory.appendingPathComponent("shelf.json"), options: .atomic)
            try JSONEncoder().encode(initial).write(to: directory.appendingPathComponent("shelf.previous.json"), options: .atomic)
            let store = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(store.configuration == current, "旧平铺布局读取不一致")
            try expect(store.previous == initial, "旧平铺撤销读取不一致")
            try store.undo()
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == initial, "旧布局撤销后无法用新格式重启")
        }

        scenario("08-旧版撤销文件的未来版本不进入主配置") { directory in
            let initial = configuration()
            var unsupported = try changed(initial)
            unsupported.version = 999
            try JSONEncoder().encode(initial).write(to: directory.appendingPathComponent("shelf.json"), options: .atomic)
            try JSONEncoder().encode(unsupported).write(to: directory.appendingPathComponent("shelf.previous.json"), options: .atomic)
            let store = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(store.previous == nil, "未来版撤销仍被启用")
            try store.undo()
            try expect(store.configuration == initial, "未来版撤销污染当前布局")
        }

        scenario("09-原子档案的未来版本撤销不进入主配置") { directory in
            let initial = configuration()
            let store = try ShelfStore(root: directory, initial: initial)
            try store.save(initial, recordUndo: false)
            let current = try changed(initial)
            try store.save(current)
            let file = directory.appendingPathComponent("shelf.json")
            guard var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  var previous = archive["previous"] as? [String: Any] else {
                throw ShelfStoreCheckError.failed("当前档案没有可验证的 previous")
            }
            previous["version"] = 999
            archive["previous"] = previous
            try JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration == current, "无效撤销损坏当前布局读取")
            try expect(reopened.previous == nil, "原子档案内未来版撤销被启用")
            try reopened.undo()
            try expect(reopened.configuration == current, "无效撤销进入主配置")
        }

        scenario("10-拒绝覆盖未来版与损坏的主配置") { directory in
            let file = directory.appendingPathComponent("shelf.json")
            var future = configuration()
            future.version = 999
            let futureBytes = try JSONEncoder().encode(future)
            try futureBytes.write(to: file, options: .atomic)
            var futureRejected = false
            do { _ = try ShelfStore(root: directory, initial: configuration()) }
            catch { futureRejected = true }
            try expect(futureRejected, "未来版主配置没有被拒绝")
            try expect(try Data(contentsOf: file) == futureBytes, "加载期间覆盖了未来版主配置")
            let invalid = Data("{\"configuration\":".utf8)
            try invalid.write(to: file, options: .atomic)
            var invalidRejected = false
            do { _ = try ShelfStore(root: directory, initial: configuration()) }
            catch { invalidRejected = true }
            try expect(invalidRejected, "损坏主配置没有被拒绝")
            try expect(try Data(contentsOf: file) == invalid, "加载期间覆盖了损坏主配置")
        }

        scenario("11-规范化布局与成员去重可持久化") { directory in
            let initial = configuration()
            let a = initial.apps(for: initial.items[0].id)[0]
            let b = initial.apps(for: initial.items[1].id)[0]
            let group = AppGroup(id: UUID(), name: "去重测试", apps: [a, a, b])
            let duplicated = ShelfConfiguration(items: [.app(a), .group(group.id), .group(group.id)], groups: [group])
            let store = try ShelfStore(root: directory, initial: duplicated)
            try store.save(store.configuration, recordUndo: false)
            let reopened = try ShelfStore(root: directory, initial: ShelfConfiguration())
            try expect(reopened.configuration.items == [.group(group.id)], "成员或分组重复占据入口")
            try expect(reopened.configuration.groups.first?.apps == [a, b], "组内重复成员未去重")
        }

        print("\n持久化 fixture：\(passed) 项通过，\(failures.count) 项失败。")
        print("测试文件全部保留：\(root.path)")
        if !failures.isEmpty { exit(EXIT_FAILURE) }
    }
}
