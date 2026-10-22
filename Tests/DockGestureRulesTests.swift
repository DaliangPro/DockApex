import AppKit

/// 不安装事件 tap、不读取 AX、不申请权限的离线测试。
@main
struct DockGestureRulesTests {
    static func main() {
        let first = DockAppItem(appURL: URL(fileURLWithPath: "/Applications/示例A.app"),
                                frame: CGRect(x: 100, y: 200, width: 60, height: 60), label: "示例A")
        let second = DockAppItem(appURL: URL(fileURLWithPath: "/Applications/示例B.app"),
                                 frame: CGRect(x: 170, y: 200, width: 60, height: 60), label: "示例B")
        let items = [first, second]
        precondition(DockGestureRules.item(at: CGPoint(x: 130, y: 230), in: items, centralOnly: false) == first)
        precondition(DockGestureRules.item(at: CGPoint(x: 200, y: 230), in: items, centralOnly: true) == second)
        precondition(DockGestureRules.item(at: CGPoint(x: 172, y: 202), in: items, centralOnly: false) == second)
        precondition(DockGestureRules.item(at: CGPoint(x: 172, y: 202), in: items, centralOnly: true) == nil)
        precondition(DockGestureRules.item(at: CGPoint(x: 200, y: 230), in: items, centralOnly: true,
                                          excluding: second.appURL) == nil)
        precondition(DockGestureRules.item(at: CGPoint(x: 500, y: 500), in: items, centralOnly: false) == nil)
        precondition(!DockGestureRules.isReady(hasDragged: false, enteredAt: 1, now: 2))
        precondition(!DockGestureRules.isReady(hasDragged: true, enteredAt: nil, now: 2))
        precondition(!DockGestureRules.isReady(hasDragged: true, enteredAt: 1, now: 1.54))
        precondition(DockGestureRules.isReady(hasDragged: true, enteredAt: 1, now: 1.56))

        // 左、右侧及主屏左方显示器使用相同的 AX / CG 全局坐标，不依赖底部 Dock 假设。
        let side = DockAppItem(appURL: first.appURL, frame: CGRect(x: -1480, y: 300, width: 60, height: 60), label: "侧边")
        precondition(DockGestureRules.item(at: CGPoint(x: -1450, y: 330), in: [side], centralOnly: true) == side)
        precondition(DockGestureRules.sourceMatches(candidate: first, actual: first, hasDragged: true))
        precondition(!DockGestureRules.sourceMatches(candidate: first, actual: second, hasDragged: false))
        precondition(!DockGestureRules.sourceMatches(candidate: first, actual: nil, hasDragged: false))
        precondition(DockGestureRules.sourceMatches(candidate: nil, actual: second, hasDragged: false))
        precondition(!DockGestureRules.sourceMatches(candidate: nil, actual: second, hasDragged: true))
        let hover = DockHoverIdentity(item: first, dockPID: 7, point: CGPoint(x:130,y:230), readAt: 5)
        // 原生已将 A 让位成 B：拖动后的点读不能推翻按下前同 URL/PID 的可信身份。
        precondition(!DockGestureRules.sourceMatches(candidate: first, actual: second, hasDragged: true)
            && DockGestureRules.trustedHover(hover, candidate: first, dockPID: 7, point: hover.point, now: 5.1) == first)
        precondition(DockGestureRules.trustedHover(hover, candidate: second, dockPID: 7, point: hover.point, now: 5.1) == nil)
        precondition(DockGestureRules.trustedHover(hover, candidate: first, dockPID: 8, point: hover.point, now: 5.1) == nil)
        precondition(DockGestureRules.trustedHover(hover, candidate: first, dockPID: 7, point: hover.point, now: 5.251) == nil)
        precondition(DockGestureRules.trustedHover(hover, candidate: first, dockPID: 7, point: CGPoint(x:145,y:230), now: 5.1) == nil)
        precondition(DockGestureRules.trustedHover(hover, candidate: first, dockPID: 7, point: hover.point, now: 4.9) == nil)
        precondition(DockGestureRules.trustedHover(hover, candidate: nil, dockPID: 7, point: hover.point, now: 5.1) == first)
        func board(_ urls: [URL], candidate: DockAppItem? = first, baseline: Int = 4, change: Int = 5,
                   confirmed: Bool = true, pid: pid_t = 7, dragged: Bool = true) -> DockAppItem? {
            DockGestureRules.dragboardSource(candidate: candidate, urls: urls, baseline: baseline, change: change,
                dockConfirmed: confirmed, dockPID: 7, currentDockPID: pid, hasDragged: dragged, knownItems: items)
        }
        precondition(board([first.appURL]) == first)
        precondition(board([first.appURL], change: 4) == nil)
        precondition(board([first.appURL], confirmed: false) == nil)
        precondition(board([first.appURL], dragged: false) == nil)
        precondition(board([first.appURL], pid: 8) == nil)
        precondition(board([second.appURL]) == nil)
        precondition(board([first.appURL, second.appURL]) == nil)
        precondition(board([URL(string:"https://example.com/A.app")!]) == nil)
        precondition(board([first.appURL], candidate: nil) == first)
        precondition(board([URL(fileURLWithPath:"/Unknown.app")], candidate: nil) == nil)
        print("通过 33 项 Dock 拖叠规则检查：中心/边缘命中、源排除、停留阈值、拖动前提及负坐标，以及按下身份核对和让位后邻居拒绝、提前悬停身份、陈旧/跨PID缓存拒绝和新拖动URL佐证。未建立事件过滤器。")
    }
}
