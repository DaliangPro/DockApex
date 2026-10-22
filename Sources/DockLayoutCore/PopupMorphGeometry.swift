import CoreGraphics
import Foundation

/// 所有矩形均为 AppKit 屏幕坐标，包含负坐标副屏；只在最外层生成一次透明画布。
struct PopupMorphGeometry: Equatable, Sendable {
    let sourceFrame: CGRect
    let targetFrame: CGRect
    let canvasFrame: CGRect

    init?(sourceFrame: CGRect, targetFrame: CGRect, backingScale: CGFloat = 1, shadowPadding: CGFloat = 18) {
        guard Self.isValid(sourceFrame), Self.isValid(targetFrame), backingScale.isFinite, backingScale > 0,
              shadowPadding.isFinite, shadowPadding >= 0 else { return nil }
        self.sourceFrame = sourceFrame
        self.targetFrame = targetFrame
        let union = sourceFrame.union(targetFrame).insetBy(dx: -shadowPadding, dy: -shadowPadding)
        let minX = floor(union.minX * backingScale) / backingScale
        let minY = floor(union.minY * backingScale) / backingScale
        let maxX = ceil(union.maxX * backingScale) / backingScale
        let maxY = ceil(union.maxY * backingScale) / backingScale
        canvasFrame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var targetInCanvas: CGRect { targetFrame.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY) }
    var sourceInCanvas: CGRect { sourceFrame.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY) }

    /// CALayer 默认围绕 bounds 中心应用 transform，因此平移就是两个屏幕中心之差。
    /// 这里不再追加按尺寸计算的 m41/m42 补偿，四角会精确落到来源矩形。
    func transform(at progress: CGFloat) -> CGAffineTransform {
        let p = min(1, max(0, progress))
        let remaining = 1 - p
        return CGAffineTransform(a: sourceFrame.width / targetFrame.width * remaining + p,
                                 b: 0, c: 0,
                                 d: sourceFrame.height / targetFrame.height * remaining + p,
                                 tx: (sourceFrame.midX - targetFrame.midX) * remaining,
                                 ty: (sourceFrame.midY - targetFrame.midY) * remaining)
    }

    /// 隐藏后首次展开必须指定来源，不能借用上次展示残留的 presentation identity。
    /// 动画中反向则保留当前变换，避免回到来源后才重新开始。
    func startingTransform(coldOpen: Bool, current: CGAffineTransform) -> CGAffineTransform {
        coldOpen ? transform(at: 0) : current
    }

    func mapTargetPoint(_ point: CGPoint, using transform: CGAffineTransform) -> CGPoint {
        let relative = CGPoint(x: point.x - targetFrame.midX, y: point.y - targetFrame.midY).applying(transform)
        return CGPoint(x: relative.x + targetFrame.midX, y: relative.y + targetFrame.midY)
    }

    func mappedFrame(using transform: CGAffineTransform) -> CGRect {
        let points = [CGPoint(x: targetFrame.minX, y: targetFrame.minY), CGPoint(x: targetFrame.maxX, y: targetFrame.minY),
                      CGPoint(x: targetFrame.maxX, y: targetFrame.maxY), CGPoint(x: targetFrame.minX, y: targetFrame.maxY)]
            .map { mapTargetPoint($0, using: transform) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// 从实际 presentation transform 读进度；透明度使用独立关键帧，不能再代替几何进度。
    func progress(of transform: CGAffineTransform) -> CGFloat {
        let sx = sourceFrame.width / targetFrame.width
        let sy = sourceFrame.height / targetFrame.height
        let raw: CGFloat
        if abs(1 - sx) > 0.000_001 { raw = (transform.a - sx) / (1 - sx) }
        else if abs(1 - sy) > 0.000_001 { raw = (transform.d - sy) / (1 - sy) }
        else if abs(sourceFrame.midX - targetFrame.midX) > 0.000_001 {
            raw = 1 - transform.tx / (sourceFrame.midX - targetFrame.midX)
        } else if abs(sourceFrame.midY - targetFrame.midY) > 0.000_001 {
            raw = 1 - transform.ty / (sourceFrame.midY - targetFrame.midY)
        } else { raw = 1 }
        return min(1, max(0, raw))
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
}
