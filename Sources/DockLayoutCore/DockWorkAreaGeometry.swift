import Foundation
import CoreGraphics

struct DockWorkAreaZone: Equatable, Sendable {
    var displayUUID: String
    var screenFrame: CGRect
    var usableFrame: CGRect
    var reservedFrame: CGRect
    var position: DockPosition
    /// 系统 Dock 隐藏前留下的可用区域，供仍保持旧半屏/四分屏几何的窗口辨认。
    var reportedVisibleFrame: CGRect? = nil
}

struct DockWorkAreaAdjustment: Equatable, Sendable {
    var frame: CGRect
    var displayUUID: String
}

/// 公开 AX 兼容避让的几何规则；不声称改变系统真正的 visibleFrame。
enum DockWorkAreaGeometry {
    /// 隐藏系统 Dock 后 NSScreen 可能短暂保留其旧的底部或侧边占位。
    /// 兼容避让以整屏左右和底边为基准，只保留真实菜单栏/刘海所在的顶部边界。
    static func normalizedUsableFrame(screenFrame: CGRect, reportedVisibleFrame: CGRect) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0,
              reportedVisibleFrame.maxY.isFinite else { return screenFrame }
        let top = min(screenFrame.maxY, max(screenFrame.minY, reportedVisibleFrame.maxY))
        guard top > screenFrame.minY else { return screenFrame }
        return CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: top - screenFrame.minY)
    }

    /// `allowIntruding`：另外接纳“大窗口伸进应用栏”——不是铺满或平铺，但高度过半、没有越出可用区顶边，
    /// 只是靠栏的一边伸进了占位（例如 App 自己按别的占位摆出的窗口）。这类窗口离栏另一侧有空间就整体挪开，
    /// 没有空间才收短靠栏的一边。用户或 App 改回去后由调用方停止接纳，避免来回较劲。
    static func adjustedFrame(_ frame: CGRect, zones: [DockWorkAreaZone], tolerance: CGFloat = 12,
                              allowIntruding: Bool = false) -> DockWorkAreaAdjustment? {
        guard frame.width >= 280, frame.height >= 160,
              frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        let ranked = zones.sorted { intersectionArea(frame, $0.screenFrame) > intersectionArea(frame, $1.screenFrame) }
        guard let zone = ranked.first, intersectionArea(frame, zone.screenFrame) >= frame.width * frame.height * 0.96 else { return nil }
        let tiled = isFilledOrTiled(frame, usableFrame: zone.usableFrame, tolerance: tolerance)
            || previousUsableFrame(for: zone).map({ isFilledOrTiled(frame, usableFrame: $0, tolerance: tolerance) }) == true
        let intruding = !tiled && allowIntruding && isLargeWindow(frame, zone: zone, tolerance: tolerance)
        guard tiled || intruding else { return nil }
        var target = frame
        switch zone.position {
        case .bottom:
            let inset = frame.minY - zone.screenFrame.minY
            guard inset >= -tolerance,
                  frame.minY < zone.reservedFrame.maxY - 1 else { return nil }
            // 小间距属于平铺外边距；较大的旧系统 Dock 占位只补足差额，不能叠加。
            let tiledGap = inset <= tolerance ? max(0, inset) : 0
            target.origin.y = zone.reservedFrame.maxY + tiledGap
            if !intruding || zone.usableFrame.maxY - frame.maxY < target.minY - frame.minY {
                target.size.height = frame.maxY - target.minY
            }
        case .left:
            let inset = frame.minX - zone.screenFrame.minX
            guard inset >= -tolerance,
                  frame.minX < zone.reservedFrame.maxX - 1 else { return nil }
            let tiledGap = inset <= tolerance ? max(0, inset) : 0
            target.origin.x = zone.reservedFrame.maxX + tiledGap
            if !intruding || zone.usableFrame.maxX - frame.maxX < target.minX - frame.minX {
                target.size.width = frame.maxX - target.minX
            }
        case .right:
            let inset = zone.screenFrame.maxX - frame.maxX
            guard inset >= -tolerance,
                  frame.maxX > zone.reservedFrame.minX + 1 else { return nil }
            let tiledGap = inset <= tolerance ? max(0, inset) : 0
            let shift = frame.maxX - (zone.reservedFrame.minX - tiledGap)
            if intruding, frame.minX - zone.usableFrame.minX >= shift { target.origin.x -= shift }
            else { target.size.width = zone.reservedFrame.minX - tiledGap - frame.minX }
        }
        guard target.width >= 280, target.height >= 160, !approximatelyEqual(target, frame) else { return nil }
        return DockWorkAreaAdjustment(frame: target, displayUUID: zone.displayUUID)
    }

    /// 悬浮条（HUD 等小浮窗）伸进应用栏时的新位置（左下原点）。已运行的 App 读不到应用栏占位，
    /// 会按“底部没有 Dock”摆放；整体挪开一个占位厚度，保留它原本离屏幕边的间距（与原生 Dock 下的位置一致），
    /// 至少挪到占位外侧；挪了会越出可用区就贴着可用区边，仍放不下返回 nil。只看高度不过可用区 35% 的窗口。
    static func floatingAdjustment(_ frame: CGRect, zones: [DockWorkAreaZone]) -> CGPoint? {
        guard frame.width >= 1, frame.height >= 1,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
        for zone in zones {
            let reserved = zone.reservedFrame, usable = zone.usableFrame
            guard frame.intersects(reserved), intersectionArea(frame, zone.screenFrame) >= frame.width * frame.height * 0.5,
                  frame.height <= usable.height * 0.35 else { continue }
            var origin = frame.origin
            switch zone.position {
            case .bottom:
                guard frame.minY < reserved.maxY - 1 else { continue }
                origin.y = min(frame.minY + max(reserved.height, reserved.maxY - frame.minY), usable.maxY - frame.height)
                guard origin.y >= reserved.maxY - 0.5 else { return nil }
            case .left:
                guard frame.minX < reserved.maxX - 1 else { continue }
                origin.x = min(frame.minX + max(reserved.width, reserved.maxX - frame.minX), usable.maxX - frame.width)
                guard origin.x >= reserved.maxX - 0.5 else { return nil }
            case .right:
                guard frame.maxX > reserved.minX + 1 else { continue }
                origin.x = max(frame.minX - max(reserved.width, frame.maxX - reserved.minX), usable.minX)
                guard origin.x + frame.width <= reserved.minX + 0.5 else { return nil }
            }
            return origin
        }
        return nil
    }

    /// 只恢复仍保持本工具最后应用尺寸的窗口，用户自己拖动或改尺寸后不再接管。
    static func restoreFrame(original: CGRect, lastApplied: CGRect, current: CGRect, tolerance: CGFloat = 1.5) -> CGRect? {
        approximatelyEqual(current, lastApplied, tolerance: tolerance) ? original : nil
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    /// 只接纳屏幕内、菜单顶沿一致且旧占位不大于当前占位的系统区域。
    /// 不以窗口自身位置猜测旧区域，避免把手动拖放的普通窗口认作平铺。
    private static func previousUsableFrame(for zone: DockWorkAreaZone) -> CGRect? {
        guard let previous = zone.reportedVisibleFrame,
              previous.width > 0, previous.height > 0,
              [previous.minX, previous.minY, previous.width, previous.height].allSatisfy(\.isFinite),
              zone.screenFrame.insetBy(dx: -0.01, dy: -0.01).contains(previous),
              abs(previous.maxY - zone.usableFrame.maxY) < 0.01 else { return nil }
        switch zone.position {
        case .bottom:
            guard abs(previous.minX - zone.usableFrame.minX) < 0.01, abs(previous.width - zone.usableFrame.width) < 0.01,
                  previous.minY > zone.screenFrame.minY, previous.minY <= zone.reservedFrame.maxY else { return nil }
        case .left:
            guard abs(previous.minY - zone.usableFrame.minY) < 0.01, abs(previous.maxX - zone.usableFrame.maxX) < 0.01,
                  previous.minX > zone.screenFrame.minX, previous.minX <= zone.reservedFrame.maxX else { return nil }
        case .right:
            guard abs(previous.minY - zone.usableFrame.minY) < 0.01, abs(previous.minX - zone.usableFrame.minX) < 0.01,
                  previous.maxX < zone.screenFrame.maxX, previous.maxX >= zone.reservedFrame.minX else { return nil }
        }
        return previous
    }

    private static func isFilledOrTiled(_ frame: CGRect, usableFrame bounds: CGRect, tolerance: CGFloat) -> Bool {
        guard bounds.width > 0, bounds.height > 0,
              frame.minX >= bounds.minX - tolerance, frame.maxX <= bounds.maxX + tolerance,
              frame.minY >= bounds.minY - tolerance, frame.maxY <= bounds.maxY + tolerance else { return false }
        let fillsHeight = abs(frame.minY - bounds.minY) <= tolerance && abs(frame.maxY - bounds.maxY) <= tolerance
        let fillsWidth = abs(frame.minX - bounds.minX) <= tolerance && abs(frame.maxX - bounds.maxX) <= tolerance
        if fillsHeight, frame.width >= bounds.width * 0.22 { return true }
        if fillsWidth, frame.height >= bounds.height * 0.22 { return true }
        // 四分屏也要避让，但普通恰好碰到屏幕底边的小窗口不能因此被移动。
        func matchesGrid(_ coordinate: CGFloat, start: CGFloat, length: CGFloat) -> Bool {
            [CGFloat(0), 0.5, 1].contains { abs(coordinate - (start + length * $0)) <= tolerance }
        }
        return frame.width >= bounds.width * 0.45 && frame.height >= bounds.height * 0.45
            && matchesGrid(frame.minX, start: bounds.minX, length: bounds.width)
            && matchesGrid(frame.maxX, start: bounds.minX, length: bounds.width)
            && matchesGrid(frame.minY, start: bounds.minY, length: bounds.height)
            && matchesGrid(frame.maxY, start: bounds.minY, length: bounds.height)
    }

    /// 高度过半、没有越出可用区顶边（菜单栏以下），左右都在屏内。
    private static func isLargeWindow(_ frame: CGRect, zone: DockWorkAreaZone, tolerance: CGFloat) -> Bool {
        frame.height >= zone.usableFrame.height * 0.5 && frame.maxY <= zone.usableFrame.maxY + tolerance
            && frame.minX >= zone.screenFrame.minX - tolerance && frame.maxX <= zone.screenFrame.maxX + tolerance
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let rect = lhs.intersection(rhs)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}
