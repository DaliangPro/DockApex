import Foundation
import Testing
@testable import DockLayoutCore

private func application(_ name: String) -> AppReference {
    AppReference(path: "/Applications/\(name).app", name: name, bundleIdentifier: "test.\(name)")
}

@Test func `两个入口真正变成一个分组且保留目标位置`() throws {
    let a = application("A"), b = application("B"), c = application("C")
    var layout = ShelfConfiguration(items: [.app(a), .app(c), .app(b)])
    let result = layout.merge(sourceID: ShelfItem.app(a).id, targetID: ShelfItem.app(b).id)
    let groupID = try #require(result)
    #expect(layout.items == [.app(c), .group(groupID)])
    #expect(layout.apps(for: ShelfItem.group(groupID).id) == [b, a])
}

@Test func `分组合并保留目标组名称并消除重复成员`() throws {
    let a = application("A"), b = application("B"), c = application("C")
    let target = AppGroup(id: UUID(), name: "工作", apps: [a, b])
    let source = AppGroup(id: UUID(), name: "工具", apps: [b, c])
    var layout = ShelfConfiguration(items: [.group(source.id), .group(target.id)], groups: [target, source])
    let result = layout.merge(sourceID: ShelfItem.group(source.id).id, targetID: ShelfItem.group(target.id).id)
    #expect(result == target.id)
    #expect(layout.items.count == 1)
    #expect(layout.groups.count == 1)
    #expect(layout.groups.first?.name == "工作")
    #expect(layout.groups.first?.apps == [a, b, c])
}

@Test func `解散分组在原位置恢复成员并且可以往返编码`() throws {
    let a = application("A"), b = application("B"), c = application("C")
    let group = AppGroup(id: UUID(), name: "常用", apps: [a, b])
    var layout = ShelfConfiguration(items: [.app(c), .group(group.id)], groups: [group], position: .left, autoHide: true)
    layout.dissolve(group.id)
    #expect(layout.items == [.app(c), .app(a), .app(b)])
    #expect(layout.groups.isEmpty)
    let decoded = try JSONDecoder().decode(ShelfConfiguration.self, from: JSONEncoder().encode(layout))
    #expect(decoded == layout)
}

@Test func `排序使用删除前缝隙索引避免错一格`() {
    let a = application("A"), b = application("B"), c = application("C")
    var layout = ShelfConfiguration(items: [.app(a), .app(b), .app(c)])
    layout.reorder(id: ShelfItem.app(a).id, insertionIndex: 3)
    #expect(layout.items == [.app(b), .app(c), .app(a)])
    layout.reorder(id: ShelfItem.app(a).id, insertionIndex: 0)
    #expect(layout.items == [.app(a), .app(b), .app(c)])
}

@Test func `规范化防止组内成员重复占据应用栏`() {
    let a = application("A"), b = application("B")
    let group = AppGroup(id: UUID(), name: "组", apps: [a, a, b])
    var layout = ShelfConfiguration(items: [.app(a), .group(group.id), .group(group.id)], groups: [group])
    layout.normalize()
    #expect(layout.items == [.group(group.id)])
    #expect(layout.groups.first?.apps == [a, b])
}

@Test func `旧版布局缺少偏好文件入口近期项仍可读取`() throws {
    let data = Data(#"{"version":1,"items":[],"groups":[],"position":"bottom","autoHide":false}"#.utf8)
    let old = try JSONDecoder().decode(ShelfConfiguration.self, from: data)
    #expect(old.options == nil)
    #expect(old.files == nil)
    #expect(old.recentApplications == nil)
}

@Test func `应用分组操作不改变文件入口和显示偏好`() throws {
    let a = application("A"), b = application("B")
    let file = ShelfFile(url: URL(fileURLWithPath: "/tmp/含空格 文件.txt"))
    let options = ShelfOptions(iconSize: 48, maximumIconSize: 80, magnification: false)
    var layout = ShelfConfiguration(items: [.app(a), .app(b)], options: options, files: [file])
    let mergedID = layout.merge(sourceID: ShelfItem.app(a).id, targetID: ShelfItem.app(b).id)
    let id = try #require(mergedID)
    layout.dissolve(id)
    let reopened = try JSONDecoder().decode(ShelfConfiguration.self, from: JSONEncoder().encode(layout))
    #expect(reopened.files == [file])
    #expect(reopened.options == options)
}

@Test func `卸载的应用从应用栏分组和最近使用中移除且空分组随之消失`() {
    let a = application("A"), b = application("B"), gone = application("Gone"), solo = application("Solo")
    let group = AppGroup(id: UUID(), name: "常用", apps: [a, gone, b])
    let lonely = AppGroup(id: UUID(), name: "只剩它", apps: [solo])
    var layout = ShelfConfiguration(items: [.app(gone), .group(group.id), .group(lonely.id)], groups: [group, lonely],
                                    recentApplications: [gone, a])
    let changes = layout.updateApplications { $0 == gone || $0 == solo ? .remove : .keep }
    #expect(layout.items == [.group(group.id)])
    #expect(layout.groups.map(\.apps) == [[a, b]])
    #expect(layout.recentApplications == [a])
    #expect(changes == [gone: .remove, solo: .remove])
}

@Test func `移动或重装的应用原位替换并保留分组位置`() {
    let a = application("A"), b = application("B"), old = application("Old")
    let moved = AppReference(path: "/Users/test/Applications/Old.app", name: "Old", bundleIdentifier: old.bundleIdentifier)
    let group = AppGroup(id: UUID(), name: "常用", apps: [a, old, b])
    var layout = ShelfConfiguration(items: [.app(old), .group(group.id)], groups: [group], recentApplications: [old])
    // 同一应用同时是固定项和分组成员属于旧数据；规范化后只留分组里的一份。
    layout.updateApplications { $0 == old ? .replace(moved) : .keep }
    #expect(layout.groups.first?.apps == [a, moved, b])
    #expect(layout.items == [.group(group.id)])
    #expect(layout.recentApplications == [moved])
}

@Test func `同一路径带旧包名的副本单独更新`() {
    let current = application("Hermes")
    let stale = AppReference(path: current.path, name: current.name, bundleIdentifier: "test.old")
    let group = AppGroup(id: UUID(), name: "常用", apps: [current])
    var layout = ShelfConfiguration(items: [.group(group.id)], groups: [group], recentApplications: [stale])
    layout.updateApplications { $0.bundleIdentifier == "test.old" ? .replace(current) : .keep }
    #expect(layout.recentApplications == [current])
    #expect(layout.groups.first?.apps == [current])
}

@Test func `替换后与已有入口重复时只保留一份`() {
    let a = application("A"), old = application("Old")
    let current = AppReference(path: a.path, name: a.name, bundleIdentifier: a.bundleIdentifier)
    var layout = ShelfConfiguration(items: [.app(old), .app(a)])
    layout.updateApplications { $0 == old ? .replace(current) : .keep }
    #expect(layout.items == [.app(a)])
}

@Test func `启动器与它拉起的主程序按名字和标识后缀对应`() {
    let setup = AppReference(path: "/Applications/Hermes.app", name: "Hermes", bundleIdentifier: "com.nousresearch.hermes.setup")
    let desktop = AppReference(path: "/Users/test/.hermes/release/Hermes.app", name: "Hermes", bundleIdentifier: "com.nousresearch.hermes")
    #expect(setup.launches(desktop))
    #expect(!desktop.launches(setup))
    // 名字不同、标识只是字符前缀、同一路径、缺标识，都不算。
    #expect(!AppReference(path: setup.path, name: "Hermes Setup", bundleIdentifier: setup.bundleIdentifier).launches(desktop))
    #expect(!AppReference(path: setup.path, name: "Hermes", bundleIdentifier: "com.nousresearch.hermesx").launches(desktop))
    #expect(!AppReference(path: desktop.path, name: "Hermes", bundleIdentifier: setup.bundleIdentifier).launches(desktop))
    #expect(!AppReference(path: setup.path, name: "Hermes", bundleIdentifier: nil).launches(desktop))
}

@Test func `整组成员都被移除后装回来，按原名原位重建分组`() throws {
    let a = application("A"), b = application("B"), first = application("First")
    let group = AppGroup(id: UUID(), name: "一起更新", apps: [a, b])
    var layout = ShelfConfiguration(items: [.app(first), .group(group.id)], groups: [group])
    let placements = try [a, b].map { try #require(layout.placement(of: $0)) }
    layout.updateApplications { $0 == first ? .keep : .remove }
    #expect(layout.groups.isEmpty && layout.items == [.app(first)])
    // 装回来的顺序与原来相反，组内顺序仍按原位。
    let restoredB = layout.restore(b, at: placements[1])
    let restoredA = layout.restore(a, at: placements[0])
    #expect(restoredA && restoredB)
    #expect(layout.items == [.app(first), .group(group.id)])
    #expect(layout.groups.first?.name == "一起更新")
    #expect(layout.groups.first?.apps == [a, b])
}

@Test func `应用文件夹的无关写入不触发核对`() {
    let apps: Set<String> = ["/Applications/Safari.app", "/Users/test/Coding/Tool/build/Tool.app"]
    let changed = FolderLayout.relevantApplicationChanges([
        "/Applications/Safari.app/Contents/Info.plist",          // 引用的应用更新
        "/Applications/新装.app",                                  // 第一层装上新应用
        "/Applications/新装.app/Contents/MacOS/新装",              // 新应用内部，不是引用的应用
        "/Users/test/Coding/Tool/build/obj/main.o",               // 开发目录里的构建产物
        "/Users/test/Coding/Tool/build/Tool.app/",                // 引用的应用本身（目录事件带斜杠）
        "/Users/test/Applications/某个.app",                       // 额外监视的文件夹
        "/Applications/Utilities/某工具.app"                       // 没监视的子文件夹
    ], applications: apps, extraFolders: ["/Applications", "/Users/test/Applications"])
    #expect(changed == ["/Applications/Safari.app/Contents/Info.plist", "/Applications/新装.app",
                        "/Users/test/Coding/Tool/build/Tool.app", "/Users/test/Applications/某个.app"])
}

@Test func `自动移除的应用很快装回来时放回原位`() throws {
    let a = application("A"), b = application("B"), gone = application("Gone"), x = application("X"), y = application("Y"), member = application("Member")
    let group = AppGroup(id: UUID(), name: "常用", apps: [x, member, y])
    var layout = ShelfConfiguration(items: [.app(a), .app(gone), .group(group.id), .app(b)], groups: [group])
    let pinned = try #require(layout.placement(of: gone))
    let grouped = try #require(layout.placement(of: member))
    #expect(pinned == .pinned(index: 1))
    #expect(grouped == .group(group.id, name: "常用", slot: 2, index: 1))
    layout.updateApplications { $0 == gone || $0 == member ? .remove : .keep }
    #expect(layout.items == [.app(a), .group(group.id), .app(b)])
    let restoredPinned = layout.restore(gone, at: pinned)
    let restoredMember = layout.restore(member, at: grouped)
    #expect(restoredPinned && restoredMember)
    #expect(layout.items == [.app(a), .app(gone), .group(group.id), .app(b)])
    #expect(layout.groups.first?.apps == [x, member, y])
    // 已经在了就不重复放。
    let again = layout.restore(gone, at: pinned)
    #expect(!again)
}

@Test func `装到别处的同一应用也按原位放回`() {
    let a = application("A"), member = application("Member"), other = application("Other")
    let moved = AppReference(path: "/Users/test/Applications/Member.app", name: "Member", bundleIdentifier: member.bundleIdentifier)
    let group = AppGroup(id: UUID(), name: "常用", apps: [member, other])
    var layout = ShelfConfiguration(items: [.app(a), .group(group.id)], groups: [group])
    let placement = layout.placement(of: member)!
    layout.updateApplications { $0 == member ? .remove : .keep }
    let restored = layout.restore(moved, at: placement)
    #expect(restored)
    #expect(layout.groups.first?.apps == [moved, other])
}
