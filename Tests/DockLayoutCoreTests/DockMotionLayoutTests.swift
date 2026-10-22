import Foundation
import CoreGraphics
import Testing
@testable import DockLayoutCore

private let motionItems = (0..<7).map { DockMotionItem(id: "app:\($0)") }
private let motionBounds = CGRect(x: 0, y: 0, width: 700, height: 90)

@Test func `连续放大包含邻居而且图标不重叠`() throws {
    let resting = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil)
    let center = try #require(resting.frames["app:3"])
    let enlarged = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom, metrics: .init(), pointer: CGPoint(x: center.midX, y: center.midY))
    #expect(abs(try #require(enlarged.frames["app:3"]).width - 62) < 0.001)
    #expect(try #require(enlarged.frames["app:2"]).width > 37)
    let rects = motionItems.compactMap { enlarged.frames[$0.id] }
    for pair in zip(rects, rects.dropFirst()) { #expect(pair.0.maxX < pair.1.minX) }
    #expect(DockMotionLayout.hitTest(CGPoint(x: center.midX, y: center.midY), frames: enlarged.frames, orderedIDs: enlarged.orderedIDs) == "app:3")
}

@Test func `拖动占位使用删除前缝隙且邻居即时让位`() {
    #expect(DockMotionLayout.projectedOrder(["a", "b", "c"], draggedID: "a", insertionGap: 3) == ["b", "c", nil])
    #expect(DockMotionLayout.projectedOrder(["a", "b", "c"], draggedID: "c", insertionGap: 0) == [nil, "a", "b"])
    let projected = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil,
                                              draggedID: "app:0", insertionGap: 5)
    #expect(projected.frames["app:0"] == nil)
    #expect(projected.placeholder != nil)
    #expect(projected.orderedIDs == ["app:1", "app:2", "app:3", "app:4", "app:5", "app:6"])
}

@Test func `拖到目标中央立即可以合并并且离开立即解除`() {
    var intent = DockMergeIntent()
    intent.update(target: "b", point: CGPoint(x: 50, y: 20), time: 10)
    #expect(intent.target == "b")
    intent.update(target: nil, point: CGPoint(x: 100, y: 20), time: 10.01)
    #expect(intent.target == nil)
}

@Test func `快速横移经过中央不进入合并`() {
    var intent = DockMergeIntent()
    intent.update(target: nil, point: .zero, time: 1)
    intent.update(target: "b", point: CGPoint(x: 50, y: 0), time: 1.05)
    #expect(intent.target == nil)
    // 在目标中央慢下来就立即可以合并。
    intent.update(target: "b", point: CGPoint(x: 50, y: 0), time: 1.1)
    #expect(intent.target == "b")
}

@Test func `中央容忍高频鼠标事件的一点抖动`() {
    var intent = DockMergeIntent()
    intent.update(target: "b", point: CGPoint(x: 50, y: 20), time: 10)
    // 触控板在 1 ms 内移动 1 点，并没有离开稳定半径，不能撤销合并。
    intent.update(target: "b", point: CGPoint(x: 51, y: 20), time: 10.001)
    #expect(intent.target == "b")
}

@Test func `已就绪的合并在快速移出稳定半径时撤销`() {
    var intent = DockMergeIntent()
    intent.update(target: "b", point: CGPoint(x: 50, y: 20), time: 10)
    intent.update(target: "b", point: CGPoint(x: 51, y: 20), time: 10.001)
    #expect(intent.target == "b")
    intent.update(target: "b", point: CGPoint(x: 70, y: 20), time: 10.002)
    #expect(intent.target == nil)
}

@Test func `迟到时间戳不把静止误判成快移但离开仍立即取消`() {
    var intent = DockMergeIntent()
    intent.update(target: "b", point: CGPoint(x: 50, y: 20), time: 10.56)
    intent.update(target: "b", point: CGPoint(x: 50, y: 20), time: 10.54)
    #expect(intent.target == "b")
    intent.update(target: nil, point: CGPoint(x: 50, y: 20), time: 10.53)
    #expect(intent.target == nil)
}

@Test func `系统入口不能成组且已有候选容忍轻微边界抖动`() throws {
    let items = [DockMotionItem(id: "a"), DockMotionItem(id: "system:trash", canMerge: false)]
    let snapshot = DockMotionLayout.snapshot(items: items, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil)
    let trash = try #require(snapshot.frames["system:trash"])
    #expect(DockMotionLayout.mergeTarget(point: CGPoint(x: trash.midX, y: trash.midY), items: items, frames: snapshot.frames, excluding: "a") == nil)
    let app = try #require(snapshot.frames["a"])
    let point = CGPoint(x: app.minX + app.width * 0.2, y: app.midY)
    #expect(DockMotionLayout.mergeTarget(point: CGPoint(x: app.midX, y: app.midY), items: items, frames: snapshot.frames, excluding: "system:trash") == nil)
    #expect(DockMotionLayout.mergeTarget(point: point, items: items, frames: snapshot.frames, excluding: nil) == nil)
    #expect(DockMotionLayout.mergeTarget(point: point, items: items, frames: snapshot.frames, excluding: nil, previousCandidate: "a") == "a")
}

@Test func `垂直布局命中与插入顺序遵循上到下`() throws {
    let bounds = CGRect(x: 0, y: 0, width: 90, height: 700)
    let snapshot = DockMotionLayout.snapshot(items: motionItems, in: bounds, position: .left, metrics: .init(), pointer: nil)
    let first = try #require(snapshot.frames["app:0"])
    let second = try #require(snapshot.frames["app:1"])
    #expect(first.minY > second.maxY)
    #expect(DockMotionLayout.insertionGap(point: CGPoint(x: first.midX, y: first.maxY + 5), items: motionItems, frames: snapshot.frames, position: .left) == 0)
}

@Test func `负坐标显示器热区和拖出距离不会混用坐标原点`() {
    let screen = CGRect(x: 1012, y: -1329, width: 2056, height: 1329)
    #expect(DockMotionLayout.isAtEdge(CGPoint(x: 1500, y: -1328), screen: screen, position: .bottom))
    #expect(!DockMotionLayout.isAtEdge(CGPoint(x: 1500, y: 0), screen: screen, position: .bottom))
    #expect(DockMotionLayout.distanceOutside(CGPoint(x: 50, y: 150), rect: CGRect(x: 0, y: 0, width: 100, height: 50)) == 100)
}

@Test func `动画可从当前呈现值反向而不跳回起点`() {
    let a = CGRect(x: 0, y: 0, width: 37, height: 37)
    let b = CGRect(x: 80, y: 0, width: 62, height: 62)
    let current = DockMotionLayout.interpolated(a, toward: b, fraction: 0.5)
    let reversed = DockMotionLayout.interpolated(current, toward: a, fraction: 0.5)
    #expect(reversed.minX == 20)
    #expect(reversed.width == 43.25)
}


@Test func `开始拖动保留放大尺寸与源占位宽度`() throws {
    let resting = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil)
    let source = try #require(resting.frames["app:3"])
    let expanded = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                             metrics: .init(), pointer: CGPoint(x: source.midX, y: source.midY))
    let drag = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                         metrics: .init(), pointer: nil, draggedID: "app:3", insertionGap: 3,
                                         preservedSizes: expanded.frames.mapValues(\.width))
    #expect(drag.frames["app:3"] == nil)
    #expect(drag.placeholder == expanded.frames["app:3"])
    for item in motionItems where item.id != "app:3" { #expect(drag.frames[item.id] == expanded.frames[item.id]) }
    #expect(drag.background == expanded.background)
}

@Test func `保留尺寸随拖动入口移动而不是绑定旧索引`() throws {
    let sizes: [String: CGFloat] = ["app:0": 62, "app:1": 54, "app:2": 46]
    let drag = DockMotionLayout.snapshot(items: Array(motionItems.prefix(3)), in: motionBounds, position: .bottom,
                                         metrics: .init(), pointer: nil, draggedID: "app:0", insertionGap: 3,
                                         preservedSizes: sizes)
    #expect(try #require(drag.frames["app:1"]).width == 54)
    #expect(try #require(drag.frames["app:2"]).width == 46)
    #expect(try #require(drag.placeholder).width == 62)
}

@Test func `已有中央候选在重叠释放区内优先保持`() {
    let frames = ["a": CGRect(x: 0, y: 0, width: 62, height: 62),
                  "b": CGRect(x: 20, y: 0, width: 62, height: 62)]
    let items = [DockMotionItem(id: "a"), DockMotionItem(id: "b")]
    let point = CGPoint(x: 40, y: 31)
    #expect(DockMotionLayout.mergeTarget(point: point, items: items, frames: frames,
                                        excluding: nil, previousCandidate: "b") == "b")
    #expect(DockMotionLayout.mergeTarget(point: CGPoint(x: 5, y: 31), items: items, frames: frames,
                                        excluding: nil, previousCandidate: "b") == nil)
}


@Test func `基础占位57点且玻璃按原生悬浮并不随悬停放大改变`() throws {
    let metrics = DockMotionMetrics(iconSize: 37, maximumIconSize: 62)
    #expect(DockMotionLayout.restingThickness(metrics: metrics) == 57)
    var larger = metrics
    larger.maximumIconSize = 128
    #expect(DockMotionLayout.restingThickness(metrics: larger) == 57)
    let resting = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                             metrics: metrics, pointer: nil)
    let icon = try #require(resting.frames["app:3"])
    let enlarged = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                              metrics: metrics, pointer: CGPoint(x: icon.midX, y: icon.midY))
    // 原生实测：玻璃条底边距屏幕 6 点、顶边 55.5 点；系统占位仍为 57 点。
    #expect(resting.background.minY == 6 && resting.background.maxY == 55.5)
    #expect(enlarged.background.minY == resting.background.minY && enlarged.background.maxY == resting.background.maxY)
    // 原生 tilesize 37 的图标节距为 39 点。
    let ordered = resting.orderedIDs.compactMap { resting.frames[$0] }
    #expect(abs(ordered[1].minX - ordered[0].minX - 39) < 0.001)
    let verticalBounds = CGRect(x: 0, y: 0, width: 90, height: 700)
    let left = DockMotionLayout.snapshot(items: motionItems, in: verticalBounds, position: .left, metrics: metrics, pointer: nil)
    let right = DockMotionLayout.snapshot(items: motionItems, in: verticalBounds, position: .right, metrics: metrics, pointer: nil)
    #expect(left.background.minX == 6 && left.background.maxX == 55.5)
    #expect(verticalBounds.width - right.background.minX == 55.5)
}


@Test func `拖起分区首项时保留分隔缝和所有邻居位置`() throws {
    let items = [DockMotionItem(id: "a"), DockMotionItem(id: "b", separatorBefore: true), DockMotionItem(id: "c")]
    let initial = DockMotionLayout.snapshot(items: items, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil)
    let drag = DockMotionLayout.snapshot(items: items, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil,
                                         draggedID: "b", insertionGap: 1, preservedSizes: initial.frames.mapValues(\.width))
    #expect(drag.separators == initial.separators)
    #expect(drag.background == initial.background)
    #expect(drag.placeholder == initial.frames["b"])
    #expect(drag.frames["a"] == initial.frames["a"])
    #expect(drag.frames["c"] == initial.frames["c"])
}

@Test func `分区首项移到同区末尾时分隔线留在新首项之前`() throws {
    let items = [DockMotionItem(id: "a"), DockMotionItem(id: "b", separatorBefore: true), DockMotionItem(id: "c")]
    let drag = DockMotionLayout.snapshot(items: items, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil,
                                         draggedID: "b", insertionGap: 3)
    let first = try #require(drag.frames["a"])
    let next = try #require(drag.frames["c"])
    let separator = try #require(drag.separators.first)
    #expect(drag.separators.count == 1)
    #expect(separator.minX > first.maxX)
    #expect(separator.maxX < next.minX)
    #expect(try #require(drag.placeholder).minX > next.maxX)
}

@Test func `跨入前区的占位不在前区中间带入多余分隔线`() throws {
    let items = [DockMotionItem(id: "a"), DockMotionItem(id: "b"),
                 DockMotionItem(id: "c", separatorBefore: true), DockMotionItem(id: "d")]
    let drag = DockMotionLayout.snapshot(items: items, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil,
                                         draggedID: "c", insertionGap: 1)
    let before = try #require(drag.frames["b"])
    let after = try #require(drag.frames["d"])
    let separator = try #require(drag.separators.first)
    #expect(drag.separators.count == 1)
    #expect(separator.minX > before.maxX)
    #expect(separator.maxX < after.minX)
}

@Test func `键盘展开保留真实快照且松开后从当前几何平滑收回`() throws {
    let initial = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom, metrics: .init(), pointer: nil)
    let source = try #require(initial.frames["app:3"])
    let keyboard = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                             metrics: .init(), pointer: CGPoint(x: source.midX, y: source.midY))
    let farPointer = CGPoint(x: -1000, y: -1000)
    let retained = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                             metrics: .init(), pointer: farPointer, retainedSnapshot: keyboard)
    #expect(retained == keyboard)
    #expect(try #require(retained.frames["app:3"]).width == 62)
    let released = DockMotionLayout.snapshot(items: motionItems, in: motionBounds, position: .bottom,
                                             metrics: .init(), pointer: farPointer)
    let start = try #require(retained.frames["app:3"])
    let goal = try #require(released.frames["app:3"])
    let midway = DockMotionLayout.interpolated(start, toward: goal, fraction: 0.25)
    #expect(goal.width == 37)
    #expect(midway.width > goal.width && midway.width < start.width)
    #expect(DockMotionLayout.interpolated(start, toward: goal, fraction: 0) == start)
}

@Test func `外部拖入时在空位处让出一格`() {
    #expect(DockMotionLayout.projectedOrder(["a", "b", "c"], draggedID: nil, insertionGap: 1) == ["a", nil, "b", "c"])
    #expect(DockMotionLayout.projectedOrder(["a", "b"], draggedID: nil, insertionGap: 9) == ["a", "b", nil])
    #expect(DockMotionLayout.projectedOrder(["a", "b"], draggedID: nil, insertionGap: nil) == ["a", "b"])
    let items = ["a", "b", "c"].map { DockMotionItem(id: $0, canMerge: true, separatorBefore: false) }
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 80)
    let resting = DockMotionLayout.snapshot(items: items, in: bounds, position: .bottom, metrics: DockMotionMetrics(), pointer: nil)
    let opened = DockMotionLayout.snapshot(items: items, in: bounds, position: .bottom, metrics: DockMotionMetrics(), pointer: nil, insertionGap: 1)
    // 让出一格后 b、c 右移，栏变宽。
    #expect(opened.frames["b"]!.minX > resting.frames["b"]!.minX)
    #expect(opened.background.width > resting.background.width)
}
