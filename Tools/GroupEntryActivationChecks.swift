import AppKit

@main
struct GroupEntryActivationChecks {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        var cold = GroupEntryActivationGate()
        expect(!cold.reopen(now: 0), "冷启动前不重复转发")
        expect(cold.didFinishLaunching(preparesOnly: false, now: 1), "冷启动展开一次")
        expect(!cold.didFinishLaunching(preparesOnly: false, now: 1.1), "启动回调不重复")
        expect(!cold.reopen(now: 1.05), "紧邻重复事件自然合并")
        expect(cold.reopen(now: 2), "后续点击可以关闭")
        expect(cold.reopen(now: 3), "第三次点击仍可重新展开")
        var warm = GroupEntryActivationGate()
        expect(!warm.didFinishLaunching(preparesOnly: true, now: 10), "预热不展开")
        expect(warm.reopen(now: 10.01), "预热后的第一个真实点击不被节流")
        expect(warm.reopen(now: 11), "预热后可以继续点击")
        let ownerFlags = ["--dockfolders-owner-pid", "1234", "--dockfolders-owner-start", "1234567890.123456"]
        expect(GroupEntryOwnerRequest(arguments: ownerFlags)?.processIdentifier == 1234, "预热解析正确主进程")
        expect(GroupEntryOwnerRequest(arguments: ownerFlags)?.launchTime == 1234567890.123456, "预热保留进程启动身份")
        expect(GroupEntryOwnerRequest(arguments: []) == nil, "缺少身份不能预热")
        expect(GroupEntryOwnerRequest(arguments: ["--dockfolders-owner-pid", "0", "--dockfolders-owner-start", "1"]) == nil, "拒绝无效 PID")
        expect(GroupEntryOwnerRequest(arguments: ["--dockfolders-owner-pid", "1", "--dockfolders-owner-start", "nan"]) == nil, "拒绝非有限启动时间")
        expect(GroupEntryOwnerRequest(arguments: ownerFlags + ["--dockfolders-owner-pid", "2"]) == nil, "拒绝重复身份标记")
        print("分组入口事件检查 \(checks) 项通过；此检查不等同于原生 Dock 动画验收。")
    }
}
