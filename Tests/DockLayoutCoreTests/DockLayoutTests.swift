import Foundation
import Testing
@testable import DockLayoutCore

private func app(_ name: String) -> URL { URL(fileURLWithPath: "/Applications/\(name).app") }
private func tile(_ name: String) -> [String: Any] { DockLayout.newTile(url: app(name), label: name, bundleIdentifier: "test.\(name)") }
private func names(_ tiles: [[String: Any]]) -> [String] { tiles.compactMap { DockLayout.appURL(in: $0)?.deletingPathExtension().lastPathComponent } }

@Test func 在目标位置建组并保留其他固定项() {
    let result = DockLayout.replacing(tiles: [tile("A"), tile("B"), tile("C"), tile("D")], source: app("A"), target: app("C"), replacement: tile("Group"))
    #expect(names(result) == ["B", "Group", "D"])
}

@Test func 从运行区拖入不会误删无关固定项() {
    let result = DockLayout.replacing(tiles: [tile("A"), tile("B")], source: app("Running"), target: app("OtherRunning"), replacement: tile("Group"))
    #expect(names(result) == ["A", "B", "Group"])
}

@Test func 合并已有组只接替两个相关入口() {
    let result = DockLayout.replacing(tiles: [tile("OldGroup"), tile("A"), tile("TargetGroup"), tile("C")], source: app("OldGroup"), target: app("TargetGroup"), replacement: tile("TargetGroup"))
    #expect(names(result) == ["A", "TargetGroup", "C"])
}

@Test func 保留分隔项及原有身份数据() {
    var original = tile("C")
    var data = original["tile-data"] as! [String: Any]
    data["book"] = Data([1, 2, 3])
    original["tile-data"] = data
    let spacer: [String: Any] = ["tile-type": "spacer-tile", "GUID": 88]
    let result = DockLayout.replacing(tiles: [tile("A"), spacer, tile("B"), original], source: app("A"), target: app("B"), replacement: tile("Group"))
    #expect(result[0]["tile-type"] as? String == "spacer-tile")
    #expect(NSDictionary(dictionary: result[2]).isEqual(NSDictionary(dictionary: original)))
    #expect((result[1]["tile-data"] as? [String: Any])?["book"] == nil)
}

@Test func 空格中文路径按URL身份匹配() {
    let source = app("测试 App")
    let item = DockLayout.newTile(url: source, label: "测试 App", bundleIdentifier: nil)
    #expect(DockLayout.appURL(in: item)?.path == source.path)
    #expect(names(DockLayout.replacing(tiles: [item, tile("B")], source: source, target: app("B"), replacement: tile("Group"))) == ["Group"])
}

@Test func Dock补写书签不影响恢复身份判断() {
    let before = [tile("Group"), tile("A")]
    var after = before
    var data = after[0]["tile-data"] as! [String: Any]
    data["book"] = Data([42])
    data["file-mod-date"] = 12345
    after[0]["tile-data"] = data
    #expect(DockLayout.identities(before) == DockLayout.identities(after))
    #expect(DockLayout.identities(before) != DockLayout.identities(Array(after.reversed())))
}
