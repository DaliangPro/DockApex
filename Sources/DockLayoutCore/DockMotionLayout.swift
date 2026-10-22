import Foundation
import CoreGraphics

/// 绘制、命中与无障碍共用的图标几何；不依赖 AppKit，也不读写系统状态。
struct DockMotionItem: Equatable, Sendable {
    var id: String
    var canMerge = true
    var separatorBefore = false
}

/// 数值来自本机 macOS 27 原生 Dock（tilesize 37）的辅助功能几何与 2x 像素实测：
/// 图标节距 39、分隔 17.55、玻璃两端留白约 4.5、图标画布底边距屏幕 12、玻璃条悬浮于底边约 6。
struct DockMotionMetrics: Equatable, Sendable {
    var iconSize: CGFloat = 37
    var maximumIconSize: CGFloat = 62
    var gap: CGFloat = 2
    var padding: CGFloat = 4.5
    var edgeInset: CGFloat = 12
    var separatorGap: CGFloat = 17.55
    var magnification = true
    /// 玻璃条与屏幕边缘的空隙；占位厚度仍按原生计到屏幕边缘。
    var glassInset: CGFloat = 6

    init(iconSize: CGFloat = 37, maximumIconSize: CGFloat = 62, magnification: Bool = true) {
        self.iconSize = iconSize; self.maximumIconSize = maximumIconSize; self.magnification = magnification
        let scale = max(12, iconSize) / 37
        gap = 2 * scale; padding = 4.5 * scale; separatorGap = 17.55 * scale
    }
}

struct DockMotionSnapshot: Equatable, Sendable {
    var frames: [String: CGRect]
    var background: CGRect
    var placeholder: CGRect?
    var separators: [CGRect]
    var orderedIDs: [String]
}

enum DockMotionLayout {
    /// 插入索引始终是删除源之前的缝隙索引，与 ShelfConfiguration.reorder 一致。
    /// 拖动中的临时顺序：`draggedID` 从原位置移到 `insertionGap`（以 nil 占位）；
    /// 没有被拖条目（从外部或分组面板拖入）时直接在 `insertionGap` 插入一个空位，栏上其余图标让开。
    static func projectedOrder(_ ids: [String], draggedID: String?, insertionGap: Int?) -> [String?] {
        guard let insertionGap else { return ids.map(Optional.some) }
        guard let draggedID else {
            var result = ids.map(Optional.some)
            result.insert(nil, at: min(result.count, max(0, insertionGap)))
            return result
        }
        guard let source = ids.firstIndex(of: draggedID) else { return ids.map(Optional.some) }
        var result = ids.filter { $0 != draggedID }.map(Optional.some)
        let adjusted = insertionGap - (source < insertionGap ? 1 : 0)
        result.insert(nil, at: min(result.count, max(0, adjusted)))
        return result
    }

    /// 基础玻璃条距屏幕边缘的内侧边界；放大画布不增加工作区占位。
    static func restingThickness(metrics: DockMotionMetrics) -> CGFloat {
        max(12, metrics.iconSize) + metrics.edgeInset + 8
    }

    static func baseLength(items: [DockMotionItem], metrics: DockMotionMetrics) -> CGFloat {
        CGFloat(items.count) * metrics.iconSize + CGFloat(max(0, items.count - 1)) * metrics.gap
            + CGFloat(items.filter(\.separatorBefore).count) * metrics.separatorGap + metrics.padding * 2
    }

    static func snapshot(items: [DockMotionItem], in bounds: CGRect, position: DockPosition,
                         metrics: DockMotionMetrics, pointer: CGPoint?, retainedSnapshot: DockMotionSnapshot? = nil,
                         draggedID: String? = nil,
                         insertionGap: Int? = nil, preservedSizes: [String: CGFloat] = [:],
                         scrollOffset: CGFloat = 0) -> DockMotionSnapshot {
        // 展开来源保留实际呈现几何，键盘和无障碍打开不依赖鼠标位置。
        if let retainedSnapshot { return retainedSnapshot }
        let order = projectedOrder(items.map(\.id), draggedID: draggedID, insertionGap: insertionGap)
        let axisLength = position == .bottom ? bounds.width : bounds.height
        let base = max(12, metrics.iconSize)
        let maximum = max(base, metrics.maximumIconSize)
        // 分隔线属于分区边界，不能随首项被替换成占位后消失或跟着首项游走。
        var region = 0
        var regions: [String: Int] = [:]
        for item in items {
            if item.separatorBefore { region += 1 }
            regions[item.id] = region
        }
        var projectedRegions = order.map { $0.flatMap { regions[$0] } }
        if let placeholderIndex = order.firstIndex(where: { $0 == nil }) {
            let before = projectedRegions[..<placeholderIndex].reversed().compactMap { $0 }.first
            let after = projectedRegions[(placeholderIndex + 1)...].compactMap { $0 }.first
            // 外部拖入没有原分区：落在分区交界时归前一个分区。
            let own = draggedID.flatMap { regions[$0] }
            if before == after { projectedRegions[placeholderIndex] = before ?? own }
            else if before == nil { projectedRegions[placeholderIndex] = after ?? own }
            else if after == nil { projectedRegions[placeholderIndex] = before ?? own }
            else { projectedRegions[placeholderIndex] = own ?? before }
        }
        let extraGaps: [CGFloat] = projectedRegions.indices.map { index in
            index > 0 && projectedRegions[index] != projectedRegions[index - 1] ? metrics.separatorGap : 0
        }
        let restingLength = CGFloat(order.count) * base + CGFloat(max(0, order.count - 1)) * metrics.gap + extraGaps.reduce(0, +)
        var cursor = (axisLength - restingLength) / 2 - scrollOffset
        var restingCenters: [CGFloat] = []
        for index in order.indices {
            cursor += extraGaps[index]
            restingCenters.append(cursor + base / 2)
            cursor += base + metrics.gap
        }
        let pointerAxis = pointer.map { position == .bottom ? $0.x : bounds.height - $0.y }
        // 原生实测（tilesize 37、largesize 62，指针在图标中心）：62 / 58.6 / 49.5 / 38.6 / 37，
        // 符合 cos(π/2 · d / R)、R ≈ 3.05 个节距。
        let influence = (base + metrics.gap) * 3.05
        let sizes = restingCenters.enumerated().map { index, center -> CGFloat in
            // 拖动期间保留抓取时的尺寸，图标不会因开始拖动而整排缩回。
            if let id = order[index] ?? draggedID, let size = preservedSizes[id], size.isFinite {
                return min(maximum, max(12, size))
            }
            guard metrics.magnification, draggedID == nil, let pointerAxis else { return base }
            let distance = min(1, abs(pointerAxis - center) / influence)
            let weight = cos(distance * .pi / 2)
            return base + (maximum - base) * weight
        }
        let total = sizes.reduce(0, +) + CGFloat(max(0, order.count - 1)) * metrics.gap + extraGaps.reduce(0, +)
        cursor = (axisLength - total) / 2 - scrollOffset
        var frames: [String: CGRect] = [:]
        var placeholder: CGRect?
        var separators: [CGRect] = []
        var union = CGRect.null
        for index in order.indices {
            let extra = extraGaps[index]
            if extra > 0 {
                let middle = cursor + extra / 2 - metrics.gap / 2
                let separator = position == .bottom
                    ? CGRect(x: middle, y: metrics.edgeInset + 2, width: 1, height: base - 4)
                    : CGRect(x: position == .left ? metrics.edgeInset + 2 : bounds.width - metrics.edgeInset - base + 2,
                             y: bounds.height - middle, width: base - 4, height: 1)
                separators.append(separator)
            }
            cursor += extra
            let size = sizes[index]
            let rect: CGRect
            switch position {
            case .bottom: rect = CGRect(x: cursor, y: metrics.edgeInset, width: size, height: size)
            case .left: rect = CGRect(x: metrics.edgeInset, y: bounds.height - cursor - size, width: size, height: size)
            case .right: rect = CGRect(x: bounds.width - metrics.edgeInset - size, y: bounds.height - cursor - size, width: size, height: size)
            }
            union = union.union(rect)
            if let id = order[index] { frames[id] = rect } else { placeholder = rect }
            cursor += size + metrics.gap
        }
        if union.isNull { union = CGRect(x: bounds.midX - 25, y: metrics.edgeInset, width: 50, height: base) }
        let background: CGRect
        let thickness = restingThickness(metrics: metrics)
        let glass = thickness - metrics.glassInset - 1.5
        switch position {
        case .bottom: background = CGRect(x: union.minX - metrics.padding, y: metrics.glassInset, width: union.width + metrics.padding * 2, height: glass)
        case .left: background = CGRect(x: metrics.glassInset, y: union.minY - metrics.padding, width: glass, height: union.height + metrics.padding * 2)
        case .right: background = CGRect(x: bounds.width - metrics.glassInset - glass, y: union.minY - metrics.padding, width: glass, height: union.height + metrics.padding * 2)
        }
        return DockMotionSnapshot(frames: frames, background: background, placeholder: placeholder, separators: separators,
                                  orderedIDs: order.compactMap { $0 })
    }

    static func hitTest(_ point: CGPoint, frames: [String: CGRect], orderedIDs: [String], expansion: CGFloat = 3) -> String? {
        orderedIDs.first { frames[$0]?.insetBy(dx: -expansion, dy: -expansion).contains(point) == true }
    }

    static func insertionGap(point: CGPoint, items: [DockMotionItem], frames: [String: CGRect],
                             position: DockPosition, excluding source: String? = nil) -> Int {
        let axis = position == .bottom ? point.x : -point.y
        for (index, item) in items.enumerated() where item.id != source {
            guard let frame = frames[item.id] else { continue }
            if axis < (position == .bottom ? frame.midX : -frame.midY) { return index }
        }
        return items.count
    }

    static func mergeTarget(point: CGPoint, items: [DockMotionItem], frames: [String: CGRect],
                            excluding source: String?, previousCandidate: String? = nil) -> String? {
        if let source, items.first(where: { $0.id == source })?.canMerge == false { return nil }
        // 已进入的中央目标先使用较宽的释放区，避免让位或手部微动切换目标。
        if let previousCandidate, previousCandidate != source,
           items.first(where: { $0.id == previousCandidate })?.canMerge == true,
           let frame = frames[previousCandidate],
           frame.insetBy(dx: frame.width * 0.17, dy: frame.height * 0.17).contains(point) {
            return previousCandidate
        }
        return items.first { item in
            guard item.canMerge, item.id != source, let frame = frames[item.id] else { return false }
            return frame.insetBy(dx: frame.width * 0.27, dy: frame.height * 0.27).contains(point)
        }?.id
    }

    static func distanceOutside(_ point: CGPoint, rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    static func isAtEdge(_ point: CGPoint, screen: CGRect, position: DockPosition, tolerance: CGFloat = 4) -> Bool {
        switch position {
        case .bottom: return abs(point.y - screen.minY) <= tolerance && point.x >= screen.minX && point.x <= screen.maxX
        case .left: return abs(point.x - screen.minX) <= tolerance && point.y >= screen.minY && point.y <= screen.maxY
        case .right: return abs(point.x - screen.maxX) <= tolerance && point.y >= screen.minY && point.y <= screen.maxY
        }
    }

    static func interpolated(_ current: CGRect, toward target: CGRect, fraction: CGFloat) -> CGRect {
        let t = min(1, max(0, fraction))
        return CGRect(x: current.minX + (target.minX - current.minX) * t,
                      y: current.minY + (target.minY - current.minY) * t,
                      width: current.width + (target.width - current.width) * t,
                      height: current.height + (target.height - current.height) * t)
    }
}

/// 拖到另一图标中央即可合并；指针快速划过中央（排序时经过别的图标）不算。
struct DockMergeIntent: Equatable, Sendable {
    private(set) var target: String?
    private var anchor = CGPoint.zero
    private var lastPoint: CGPoint?
    private var lastTime: TimeInterval?
    var stableRadius: CGFloat = 9
    var maximumSpeed: CGFloat = 180

    mutating func update(target next: String?, point: CGPoint, time: TimeInterval) {
        // 显示回调与输入事件可能交错；迟到时间按上次时间算，不会把静止误判成快移。
        let sampleTime = max(time, lastTime ?? time)
        let speed: CGFloat
        if let lastPoint, let lastTime {
            let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            speed = sampleTime > lastTime ? distance / CGFloat(sampleTime - lastTime) : (distance == 0 ? 0 : .infinity)
        } else { speed = 0 }
        self.lastPoint = point
        self.lastTime = sampleTime
        guard let next else { target = nil; return }
        // 稳定半径内的细小抖动不能按单个事件的瞬时速度撤销。
        // 例如 1 ms 移动 1 点虽然算出 1000 点/秒，手指仍停在同一目标中央。
        if target == next, hypot(point.x - anchor.x, point.y - anchor.y) <= stableRadius { return }
        guard speed <= maximumSpeed else { target = nil; return }
        target = next; anchor = point
    }

    mutating func reset() { self = DockMergeIntent(stableRadius: stableRadius, maximumSpeed: maximumSpeed) }
}
