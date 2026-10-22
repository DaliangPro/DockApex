import AppKit
import QuartzCore

/// 离屏 AppKit 事件回归：调用产品视图的鼠标入口，不安装事件 tap、不触碰真实布局、不显示窗口。
/// 它验证事件到模型的路径，不代表真人拖动手感或 WindowServer 最终合成帧率验收。
@main
struct DockSurfaceInteractionChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            precondition(value(), reason)
            checks += 1
        }

        let stationary = Fixture()
        stationary.beginDrag()
        stationary.wait(at: stationary.targetCenter, duration: 0.68, refreshingRuntime: true)
        check(stationary.hints.contains("松开创建分组"), "停止发送 mouseDragged 后，显示回调应继续完成中央停留")
        stationary.release(at: stationary.targetCenter)
        check(stationary.mergeCount == 1, "完整鼠标路径应只提交一次合并")
        check(stationary.configuration.items.count == 1, "两个入口应真实合成一个位置")
        check(stationary.configuration.groups.first?.apps.count == 2, "新分组应含有两个真实模型成员")
        check(stationary.surface.subviews.compactMap { $0 as? DockMotionIcon }.count == 1, "渲染层应只剩一个分组图标")
        check(!stationary.panel.isVisible, "事件回归不能把测试面板显示到用户桌面")

        let short = Fixture()
        short.beginDrag()
        short.wait(at: short.targetCenter, duration: 0.16)
        short.release(at: short.targetCenter)
        check(short.mergeCount == 0, "快速经过不能合并")
        check(short.configuration.groups.isEmpty, "短停留不能生成分组模型")

        let futureFrame = Fixture()
        futureFrame.beginDrag()
        futureFrame.advance(at: futureFrame.targetCenter, predictedFrameOffset: 2)
        check(!futureFrame.hints.contains("松开创建分组"), "未来显示时间不能提前完成真实停留")
        futureFrame.release(at: futureFrame.targetCenter)
        check(futureFrame.mergeCount == 0, "输入松手不能继承未来帧伪造的停留")

        let fastArrival = Fixture()
        let sourceFrame = fastArrival.icon(fastArrival.sourceID).frame
        fastArrival.beginDrag(to: CGPoint(x: sourceFrame.midX + 6, y: sourceFrame.midY))
        fastArrival.icon(fastArrival.sourceID).mouseDragged(with: fastArrival.event(.leftMouseDragged, at: fastArrival.targetCenter))
        fastArrival.wait(at: fastArrival.targetCenter, duration: 0.68)
        fastArrival.release(at: fastArrival.targetCenter)
        check(fastArrival.mergeCount == 1, "快速移入中央再停住时，目标不能先被排序让位推走")

        let cancelled = Fixture()
        cancelled.beginDrag()
        cancelled.wait(at: cancelled.targetCenter, duration: 0.68)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: cancelled.panel.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        cancelled.surface.keyDown(with: escape)
        cancelled.release(at: cancelled.targetCenter)
        check(cancelled.mergeCount == 0 && cancelled.reorderCount == 0, "Esc 取消后 mouseUp 不得再提交合并或排序")
        check(cancelled.openCount == 0, "取消拖动不得误当成应用单击")
        check(!cancelled.surface.isDragging, "取消后不能遗留拖动状态")

        let edge = Fixture()
        let edgePoint = CGPoint(x: edge.targetCenter.x + 14, y: 11)
        edge.beginDrag(to: edgePoint)
        edge.wait(at: edgePoint, duration: 0.68)
        edge.release(at: edgePoint)
        check(edge.mergeCount == 0 && edge.reorderCount == 1, "图标边缘停留应排序而非合并")
        check(edge.configuration.items.last?.id == edge.sourceID, "边缘拖动应移动源入口到目标后方")

        let groupIcon = stationary.icon(stationary.configuration.items[0].id)
        let groupPoint = CGPoint(x: groupIcon.frame.midX, y: groupIcon.frame.midY)
        groupIcon.mouseDown(with: stationary.event(.leftMouseDown, at: groupPoint))
        groupIcon.mouseUp(with: stationary.event(.leftMouseUp, at: groupPoint))
        check(stationary.openCount == 1, "分组单击应调用一次展开入口")
        check(!stationary.surface.needsContinuousFrames, "分组单击不能登记应用启动弹跳")

        let stack = Fixture()
        let fileID = "file:/fixture/文件夹"
        stack.surface.update(items: [DockDisplayItem(id: fileID, name: "文件夹", icon: NSImage(size: NSSize(width: 128, height: 128)),
            isRunning: false, isGroup: false, section: .files)], position: .bottom, metrics: .init(), appearance: .nativeDefaults)
        stack.advance(at: .zero)
        let stackIcon = stack.icon(fileID)
        let stackPoint = CGPoint(x: stackIcon.frame.midX, y: stackIcon.frame.midY)
        stackIcon.mouseDown(with: stack.event(.leftMouseDown, at: stackPoint))
        stackIcon.mouseUp(with: stack.event(.leftMouseUp, at: stackPoint))
        check(stack.openCount == 1 && !stack.surface.needsContinuousFrames, "文件夹入口展开也不能触发应用启动弹跳")

        let fixtures = [stationary, short, futureFrame, fastArrival, cancelled, edge, stack]
        for fixture in fixtures { fixture.surface.cancelInteraction(); fixture.panel.orderOut(nil) }
        print("通过：\(checks) 项自制 Dock 离屏鼠标事件检查。覆盖静止停留、运行状态刷新、真实单入口合并、短停留、未来帧时间、Esc、边缘排序、单击与文件夹无弹跳。未操作运行中的产品、系统设置、真实布局或用户窗口。")
    }

    @MainActor
    private final class Fixture {
        let panel: NSPanel
        let surface: DockMotionSurface
        var configuration: ShelfConfiguration
        let sourceID: String
        let targetID: String
        private(set) var targetCenter = CGPoint.zero
        var mergeCount = 0
        var reorderCount = 0
        var openCount = 0
        var hints = Set<String>()
        private var sourceView: DockMotionIcon?

        init() {
            let a = AppReference(path: "/fixture/A.app", name: "示例 A", bundleIdentifier: "fixture.A")
            let b = AppReference(path: "/fixture/B.app", name: "示例 B", bundleIdentifier: "fixture.B")
            configuration = ShelfConfiguration(items: [.app(a), .app(b)])
            sourceID = ShelfItem.app(a).id
            targetID = ShelfItem.app(b).id
            let frame = CGRect(x: -20_000, y: -20_000, width: 700, height: 90)
            panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            surface = DockMotionSurface(frame: CGRect(origin: .zero, size: frame.size))
            panel.contentView = surface
            surface.onMerge = { [weak self] source, target in
                guard let self else { return }
                self.mergeCount += 1
                precondition(self.configuration.merge(sourceID: source, targetID: target) != nil)
                self.render()
            }
            surface.onReorder = { [weak self] source, gap in
                guard let self else { return }
                self.reorderCount += 1
                self.configuration.reorder(id: source, insertionIndex: gap)
                self.render()
            }
            surface.onOpen = { [weak self] _, _ in self?.openCount += 1 }
            surface.onHint = { [weak self] text, _ in if let text { self?.hints.insert(text) } }
            render()
            let target = icon(targetID).frame
            targetCenter = CGPoint(x: target.midX, y: target.midY)
        }

        func render() {
            surface.update(items: displayItems, position: .bottom, metrics: .init(), appearance: .nativeDefaults)
        }

        var displayItems: [DockDisplayItem] {
            configuration.items.map { item in
                let isGroup: Bool
                if case .group = item { isGroup = true } else { isGroup = false }
                return DockDisplayItem(id: item.id, name: isGroup ? "示例分组" : "示例应用",
                    icon: NSImage(size: NSSize(width: 128, height: 128)), isRunning: false, isGroup: isGroup)
            }
        }

        func icon(_ id: String) -> DockMotionIcon {
            surface.subviews.compactMap { $0 as? DockMotionIcon }.first { $0.item.id == id }!
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }

        func beginDrag(to destination: CGPoint? = nil) {
            let view = icon(sourceID)
            sourceView = view
            let origin = CGPoint(x: view.frame.midX, y: view.frame.midY)
            view.mouseDown(with: event(.leftMouseDown, at: origin))
            view.mouseDragged(with: event(.leftMouseDragged, at: destination ?? targetCenter))
        }

        func release(at point: CGPoint) { sourceView?.mouseUp(with: event(.leftMouseUp, at: point)) }

        func advance(at point: CGPoint, predictedFrameOffset: TimeInterval = 1.0 / 60) {
            _ = surface.advance(time: ProcessInfo.processInfo.systemUptime + predictedFrameOffset,
                delta: 1.0 / 120, pointer: panel.convertPoint(toScreen: point))
        }

        func wait(at point: CGPoint, duration: TimeInterval, refreshingRuntime: Bool = false) {
            let deadline = ProcessInfo.processInfo.systemUptime + duration
            while ProcessInfo.processInfo.systemUptime < deadline {
                if refreshingRuntime { surface.updateRuntime(displayItems) }
                advance(at: point)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 120))
            }
        }
    }
}
