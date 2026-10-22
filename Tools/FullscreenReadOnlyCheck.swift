import AppKit
import Foundation

/// 只读取屏幕几何与候选窗口的全屏状态。不读名称，不执行 AX 动作，不捕获图像，不修改当前产品。
@main
struct FullscreenReadOnlyCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let displays = FullscreenTracker.displayGeometry()
        let sample = await Task.detached(priority: .utility) { FullscreenWindowReader.sample(displays: displays) }.value
        var output: [String: Any] = [
            "measurement": "只读可见候选的 CG 编号及 AXFullScreen/位置/尺寸/最小化；没有读取窗口名称或内容",
            "displays": displays.map { display in
                ["id": display.id, "frame": rect(display.frame), "hardwareSafeFrame": rect(display.safeFrame)] as [String: Any]
            }
        ]
        if let sample {
            output["confirmedDisplayIDs"] = sample.confirmedDisplayIDs.sorted()
            output["unresolvedDisplayIDs"] = sample.unresolvedDisplayIDs.sorted()
            output["candidateWindowCount"] = sample.candidateWindowCount
            output["queriedProcessCount"] = sample.queriedProcessCount
            output["queriedWindowCount"] = sample.queriedWindowCount
            output["hasAccessibilityPermission"] = sample.hasAccessibilityPermission
            output["budgetExhausted"] = sample.budgetExhausted
            output["elapsedMilliseconds"] = sample.elapsedMilliseconds
        } else { output["error"] = "WindowServer 读取失败或本轮取消；未确认。" }
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: encoded, as: UTF8.self))
    }

    private static func rect(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height] }
}
