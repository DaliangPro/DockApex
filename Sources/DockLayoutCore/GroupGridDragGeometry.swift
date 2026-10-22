import Foundation
import CoreGraphics

/// 网格只计算临时顺序，鼠标松开前不会修改成员数据。
enum GroupGridDragGeometry {
    /// 每格只放图标和运行指示点，名称改为悬停提示。
    static let cell = CGSize(width: 80, height: 76)

    /// 第 `index` 格的成员框（文档坐标，左下为原点，首行在顶部）。
    static func tileFrame(index: Int, columns: Int, documentHeight: CGFloat) -> CGRect {
        let columns = max(1, columns)
        return CGRect(x: CGFloat(index % columns) * cell.width + 4,
                      y: documentHeight - CGFloat(index / columns + 1) * cell.height + 2,
                      width: cell.width - 8, height: cell.height - 4)
    }

    static func frames(order: [String?], columns: Int, documentHeight: CGFloat) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for (index, id) in order.enumerated() {
            guard let id else { continue }
            result[id] = tileFrame(index: index, columns: columns, documentHeight: documentHeight)
        }
        return result
    }

    /// 缝隙沿原成员序列编号，与 DockMotionLayout.projectedOrder 的删除前索引一致。
    static func gap(at point: CGPoint, orderedIDs: [String], frames: [String: CGRect], excluding source: String,
                    placeholder: CGRect? = nil, currentGap: Int? = nil) -> Int {
        // 换行让位后，鼠标应留在同一个空位；不能因为邻居移到了上一行又把空位拉回去。
        if let placeholder, let currentGap, placeholder.insetBy(dx: -2, dy: -2).contains(point) { return currentGap }
        let candidates = orderedIDs.enumerated().compactMap { index, id -> (Int, CGRect)? in
            guard id != source, let frame = frames[id] else { return nil }
            return (index, frame)
        }
        guard !candidates.isEmpty else { return 0 }
        if point.y > candidates.map({ $0.1.maxY }).max()! + 12 { return 0 }
        if point.y < candidates.map({ $0.1.minY }).min()! - 12 { return orderedIDs.count }
        let nearestRow = candidates.min { abs($0.1.midY - point.y) < abs($1.1.midY - point.y) }!.1.midY
        let row = candidates.filter { abs($0.1.midY - nearestRow) < 2 }.sorted { $0.1.minX < $1.1.minX }
        for (index, frame) in row where point.x < frame.midX { return index }
        return min(orderedIDs.count, (row.last?.0 ?? orderedIDs.count - 1) + 1)
    }

    static func reordered(_ ids: [String], source: String, gap: Int) -> [String] {
        DockMotionLayout.projectedOrder(ids, draggedID: source, insertionGap: gap).map { $0 ?? source }
    }
}
