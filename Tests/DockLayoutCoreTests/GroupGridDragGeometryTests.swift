import CoreGraphics
import Testing
@testable import DockLayoutCore

@Test func `两成员网格落到目标前后只移动源一次`() {
    let ids = ["词典", "计算器"]
    let frames = GroupGridDragGeometry.frames(order: ids.map(Optional.some), columns: 3, documentHeight: 76)
    let before = GroupGridDragGeometry.gap(at: CGPoint(x: 85, y: 38), orderedIDs: ids, frames: frames, excluding: "词典")
    let after = GroupGridDragGeometry.gap(at: CGPoint(x: 150, y: 38), orderedIDs: ids, frames: frames, excluding: "词典")
    #expect(GroupGridDragGeometry.reordered(ids, source: "词典", gap: before) == ids)
    #expect(GroupGridDragGeometry.reordered(ids, source: "词典", gap: after) == ["计算器", "词典"])
}

@Test func `六成员网格跨行让位保留完整成员且支持反向`() {
    let ids = ["0", "1", "2", "3", "4", "5"]
    let temporary = DockMotionLayout.projectedOrder(ids, draggedID: "0", insertionGap: 6)
    let frames = GroupGridDragGeometry.frames(order: temporary, columns: 5, documentHeight: 152)
    #expect(frames["0"] == nil)
    #expect(frames["1"]?.minX == 4)
    #expect(frames["5"]?.minY == 78)
    let final = GroupGridDragGeometry.reordered(ids, source: "0", gap: 6)
    #expect(final == ["1", "2", "3", "4", "5", "0"])
    #expect(GroupGridDragGeometry.reordered(final, source: "0", gap: 0) == ids)
    #expect(Set(final) == Set(ids))
    let gap = GroupGridDragGeometry.gap(at: CGPoint(x: 40, y: 38), orderedIDs: ids, frames: frames, excluding: "0",
                                        placeholder: GroupGridDragGeometry.tileFrame(index: 5, columns: 5, documentHeight: 152), currentGap: 6)
    #expect(gap == 6)
}

@Test func `网格顶部和底部空白对应首尾缝隙`() {
    let ids = ["a", "b", "c", "d", "e", "f"]
    let frames = GroupGridDragGeometry.frames(order: ids.map(Optional.some), columns: 3, documentHeight: 152)
    #expect(GroupGridDragGeometry.gap(at: CGPoint(x: 10, y: 200), orderedIDs: ids, frames: frames, excluding: "c") == 0)
    #expect(GroupGridDragGeometry.gap(at: CGPoint(x: 10, y: -30), orderedIDs: ids, frames: frames, excluding: "c") == 6)
    #expect(ids == ["a", "b", "c", "d", "e", "f"])
}
