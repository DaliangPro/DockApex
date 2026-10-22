import Foundation

/// 坐标统一为 WindowServer 左上原点；每个显示器独立判断，前台应用可位于另一屏。
public enum DockFullscreenGeometry {
    public struct Display: Sendable {
        public let id: UInt32
        public let frame: CGRect
        public let safeFrame: CGRect
        public init(id: UInt32, frame: CGRect, safeFrame: CGRect? = nil) {
            self.id = id; self.frame = frame; self.safeFrame = safeFrame ?? frame
        }
    }

    public struct Window: Sendable {
        public let frame: CGRect
        public let isFullscreen: Bool?
        public init(frame: CGRect, isFullscreen: Bool?) { self.frame = frame; self.isFullscreen = isFullscreen }
    }

    /// 仅作后台 AX 读取前的几何筛选。safeFrame 必须来自硬件安全区，不能用受 Dock 影响的 visibleFrame。
    public static func candidateDisplays(window: CGRect, displays: [Display]) -> Set<UInt32> {
        Set(displays.compactMap { display in
            guard valid(display.frame), valid(window) else { return nil }
            let matchesFullFrame = approximatelyEqual(window, display.frame)
            let validSafeFrame = valid(display.safeFrame) && display.frame.contains(display.safeFrame)
            let matchesSafeFrame = validSafeFrame && approximatelyEqual(window, display.safeFrame)
            let matchesSplitView = splitViewCandidate(window, in: display.frame)
                || validSafeFrame && splitViewCandidate(window, in: display.safeFrame)
            guard matchesFullFrame || matchesSafeFrame || matchesSplitView else { return nil }
            return display.id
        })
    }

    /// 同样铺满屏幕的普通最大化窗口不能触发全屏策略；几何必须与 AXFullScreen=true 同时成立。
    public static func coveredDisplays(windows: [Window], displays: [Display]) -> Set<UInt32> {
        windows.filter { $0.isFullscreen == true }.reduce(into: Set<UInt32>()) { result, window in
            result.formUnion(candidateDisplays(window: window.frame, displays: displays))
        }
    }

    public static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        valid(lhs) && valid(rhs) && abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    private static func splitViewCandidate(_ window: CGRect, in frame: CGRect) -> Bool {
        // 原生双窗分屏沿左右边缘排列，可不等宽；完整高度也可能避开刘海安全区。
        // 宽度范围只约束候选读取，不冒充系统的最小窗口宽度；最终仍必须有精确窗口的 AXFullScreen=true。
        let minimumTileWidth = max(160, frame.width * 0.10)
        guard window.width >= minimumTileWidth, window.width <= frame.width - minimumTileWidth,
              abs(window.minY - frame.minY) < 2, abs(window.height - frame.height) < 2,
              window.minX >= frame.minX - 1, window.maxX <= frame.maxX + 1 else { return false }
        return abs(window.minX - frame.minX) < 2 || abs(window.maxX - frame.maxX) < 2
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
