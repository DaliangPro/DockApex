import CoreGraphics

/// 图标按下变暗，照系统 Dock：`-[DOCKTileLayer setSelected:]` 与堆栈里的 `-[DOCKStackExpandedItemLayer setDarkened:]`
/// 都给图标图层挂 multiplyColor 滤镜，inputColor 为通用灰 0.4（不透明），关掉隐式动画立即生效，松开即撤
/// （macOS 27.0.1 Dock 反汇编确认）。滤镜只挂在图标图层上，角标、名称和运行指示点不变暗，也不画选框。
enum DockPressDarkening {
    static let multiplier: CGFloat = 0.4

    /// 预乘颜色乘 0.4、透明度不变：在图标上用 sourceAtop 叠 60% 黑，结果与 multiplyColor 相同。
    static func darkened(_ image: CGImage) -> CGImage? {
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        // 沿用图标自己的 RGB 色彩空间；建不出 8 位上下文（App 图标多为 16 位扩展 sRGB）时退回 Display P3：
        // 与 sRGB 同一条传递曲线，乘 0.4 的效果一致，又不裁掉广色域颜色。
        let own = image.colorSpace.flatMap { $0.model == .rgb ? context($0) : nil }
        guard let context = own ?? context(CGColorSpace(name: CGColorSpace.displayP3)!) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        darken(context, rect)
        return context.makeImage()
    }

    /// 在已有画面上画一个按下的图标：放进透明层里画再压暗，只影响图标自己的像素，不压到底下的内容。
    static func drawPressed(in context: CGContext, rect: CGRect, icon: () -> Void) {
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        icon()
        darken(context, rect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func darken(_ context: CGContext, _ rect: CGRect) {
        context.setBlendMode(.sourceAtop)
        context.setFillColor(gray: 0, alpha: 1 - multiplier)
        context.fill(rect)
    }
}
