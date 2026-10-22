import AppKit

/// 纯状态检查：不启动应用、不读取用户窗口、不改变焦点或系统设置。
@main
struct ShelfInteractionChecks {
    static func main() {
        let own: pid_t = 900
        let source = ShelfApplicationIdentity(pid: 10, launchTime: 1, path: "/Source.app")
        let target = ShelfApplicationIdentity(pid: 20, launchTime: 2, path: "/Target.app")
        let other = ShelfApplicationIdentity(pid: 30, launchTime: 3, path: "/Other.app")
        let tool = ShelfApplicationIdentity(pid: own, launchTime: 4, path: "/DockFolders.app")
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        var state = ShelfInteractionState()
        let first = state.begin(targetPath: "/Target.app", initial: source)
        check(state.permits(first, frontmost: source, ownPID: own), "后台读取期间应允许原应用保持前台")
        check(state.permits(first, frontmost: target, ownPID: own), "本次点击的目标允许激活")
        check(!state.permits(first, frontmost: source, ownPID: own), "用户从目标切回原应用后，旧恢复不得抢回焦点")
        check(!state.permits(first, frontmost: target, ownPID: own), "失效操作即使目标再次前台也不能复活")
        let second = state.begin(targetPath: "/Target.app", initial: source)
        check(!state.permits(first, frontmost: source, ownPID: own), "新点击必须使旧回调失效")
        check(state.permits(second, frontmost: source, ownPID: own), "拒绝旧代次不能破坏新代次")
        check(!state.observe(other, ownPID: own), "用户切到第三方应用应取消旧操作")
        check(!state.permits(second, frontmost: target, ownPID: own), "第三方切换后迟到启动回调不得激活")
        let third = state.begin(targetPath: "/Target.app", initial: tool)
        check(state.permits(third, frontmost: tool, ownPID: own), "管理窗口内点击允许继续")
        check(state.permits(third, frontmost: target, ownPID: own), "管理窗口点击可激活目标")
        check(!state.permits(third, frontmost: tool, ownPID: own), "目标激活后用户返回管理窗口应取消迟到恢复")
        let fourth = state.begin(targetPath: "/Target.app", initial: source)
        let reusedPID = ShelfApplicationIdentity(pid: 10, launchTime: 99, path: "/Source.app")
        check(!state.permits(fourth, frontmost: reusedPID, ownPID: own), "起点 PID 被重用不能沿用授权")
        let fifth = state.begin(targetPath: "/Target.app", initial: nil)
        check(state.permits(fifth, frontmost: nil, ownPID: own), "无前台应用的瞬时状态不应误取消")
        check(state.permits(fifth, frontmost: target, ownPID: own), "无前台起点也允许目标激活")

        let minimized = AppWindowInfo(id: "1:min", title: "最小化", isMinimized: true, isMain: false, isFocused: false)
        let visible = AppWindowInfo(id: "1:visible", title: "可见", isMinimized: false, isMain: true, isFocused: true)
        let renamed = AppWindowInfo(id: "1:visible", title: "新标题", isMinimized: false, isMain: true, isFocused: true)
        func snapshot(pid: pid_t = 1, windows: [AppWindowInfo], complete: Bool) -> AppWindowSnapshot {
            AppWindowSnapshot(processIdentifier: pid, windows: windows, hasAccessibilityPermission: true,
                errorDescription: complete ? nil : "受控超时", updatedAt: Date(), isComplete: complete)
        }
        let previous = snapshot(windows: [minimized, visible], complete: true)
        let unread = snapshot(windows: [], complete: false).retainingUnreadWindows(from: previous)
        check(unread.windows == previous.windows, "AX 超时不得清空已知最小化窗口")
        check(!unread.isComplete, "保留旧窗口不能把不完整读数标记为完整")
        let partial = snapshot(windows: [renamed], complete: false).retainingUnreadWindows(from: previous)
        check(partial.windows == [minimized, renamed], "部分更新应更新已读窗口并保留未读窗口及顺序")
        let newWindow = AppWindowInfo(id: "1:new", title: "新窗口", isMinimized: false, isMain: false, isFocused: false)
        let extended = snapshot(windows: [newWindow], complete: false).retainingUnreadWindows(from: previous)
        check(extended.windows == [minimized, visible, newWindow], "部分读数也应接纳新窗口")
        let complete = snapshot(windows: [visible], complete: true).retainingUnreadWindows(from: previous)
        check(complete.windows == [visible], "只有完整读数可移除已关闭窗口")
        let restarted = snapshot(pid: 2, windows: [], complete: false).retainingUnreadWindows(from: previous)
        check(restarted.windows.isEmpty, "新进程不得继承旧进程窗口")
        let empty = snapshot(windows: [], complete: false).retainingUnreadWindows(from: nil)
        check(empty.windows.isEmpty, "首次读取失败不能伪造窗口")
        print("通过：\(checks) 项操作代次、焦点切换、进程身份及窗口部分读取检查；未执行 AX 动作或系统修改。")
    }
}
