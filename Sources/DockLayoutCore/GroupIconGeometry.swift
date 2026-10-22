import CoreGraphics

/// 分组图标的版式：分组图标绘制与拖叠建组动画的落点共用，保证动画终点与真实图标重合。
enum GroupIconGeometry {
    /// 与 macOS App 图标网格一致：圆角底板占画布 80.5%（824/1024），这样文件夹和相邻 App 图标视觉大小相同。
    static func plate(in canvas: CGRect) -> CGRect {
        canvas.insetBy(dx: canvas.width * 0.0977, dy: canvas.height * 0.0977)
    }

    /// 圆角约为底板边长的 22.5%。
    static func cornerRadius(of plate: CGRect) -> CGFloat { plate.width * 0.225 }

    /// 第 `index` 个成员的小图标位置（画布坐标，左下为原点，从左上起按行排列）。4 个以内用 2 列大格，否则 3 列。
    static func slot(_ index: Int, memberCount: Int, in canvas: CGRect) -> CGRect {
        let plate = plate(in: canvas)
        let large = memberCount <= 4
        let columns = large ? 2 : 3
        let padding = plate.width * (large ? 0.12 : 0.1)
        let gap = plate.width * (large ? 0.05 : 0.035)
        let side = (plate.width - padding * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let x = plate.minX + padding + CGFloat(index % columns) * (side + gap)
        let y = plate.maxY - padding - side - CGFloat(index / columns) * (side + gap)
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
