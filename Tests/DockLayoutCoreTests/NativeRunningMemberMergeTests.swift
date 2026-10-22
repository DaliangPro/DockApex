import Foundation
import Testing
@testable import DockLayoutCore

private func nativeApp(_ name: String) -> AppReference {
    AppReference(path: "/Applications/\(name).app", name: name, bundleIdentifier: "test.native.\(name)")
}

@Test func `两个组内运行图标可抽出重新建组且新组不会被去重删除`() throws {
    let a = nativeApp("A"), b = nativeApp("B"), c = nativeApp("C"), d = nativeApp("D")
    let old = AppGroup(id: UUID(), name: "原组", apps: [a,b,c,d])
    var value = ShelfConfiguration(items: [.group(old.id), .app(a), .app(b)], groups: [old])
    let merged = value.merge(sourceID: ShelfItem.app(a).id, targetID: ShelfItem.app(b).id)
    let result = try #require(merged)
    #expect(value.groups.first(where: { $0.id == old.id })?.apps == [c,d])
    #expect(value.groups.first(where: { $0.id == result })?.apps == [b,a])
    #expect(value.items == [.group(old.id), .group(result)])
}

@Test func `恰好已经在同一双成员组时保留原组名称和身份`() {
    let a = nativeApp("A"), b = nativeApp("B")
    let old = AppGroup(id: UUID(), name: "工具", apps: [a,b])
    var value = ShelfConfiguration(items: [.group(old.id), .app(a), .app(b)], groups: [old])
    let merged = value.merge(sourceID: ShelfItem.app(a).id, targetID: ShelfItem.app(b).id)
    #expect(merged == old.id)
    #expect(value.groups == [old])
    #expect(value.items == [.group(old.id)])
}

@Test func `跨两个旧组抽取运行图标时只转移所选成员`() throws {
    let a = nativeApp("A"), b = nativeApp("B"), c = nativeApp("C"), d = nativeApp("D")
    let first = AppGroup(id: UUID(), name: "一", apps: [a,b]), second = AppGroup(id: UUID(), name: "二", apps: [c,d])
    var value = ShelfConfiguration(items: [.group(first.id), .group(second.id), .app(a), .app(c)], groups: [first,second])
    let merged = value.merge(sourceID: ShelfItem.app(a).id, targetID: ShelfItem.app(c).id)
    let id = try #require(merged)
    #expect(value.groups.first(where: { $0.id == first.id })?.apps == [b])
    #expect(value.groups.first(where: { $0.id == second.id })?.apps == [d])
    #expect(value.groups.first(where: { $0.id == id })?.apps == [c,a])
    #expect(Set(value.groups.flatMap(\.apps).map(\.path)).count == 4)
}

@Test func `运行图标拖回所属分组不改变原组`() {
    let a = nativeApp("A"), b = nativeApp("B")
    let old = AppGroup(id: UUID(), name: "原组", apps: [a,b])
    var value = ShelfConfiguration(items: [.group(old.id), .app(a)], groups: [old])
    let merged = value.merge(sourceID: ShelfItem.app(a).id, targetID: ShelfItem.group(old.id).id)
    #expect(merged == old.id)
    #expect(value.groups == [old])
    #expect(value.items == [.group(old.id)])
}
