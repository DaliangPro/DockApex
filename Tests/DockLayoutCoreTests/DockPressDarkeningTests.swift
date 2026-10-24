import CoreGraphics
import Testing
@testable import DockLayoutCore

/// 三个像素（预乘 RGBA）：不透明、半透明、全透明。
private func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

private func sample() -> CGImage {
    var data: [UInt8] = [200, 100, 50, 255, 100, 50, 20, 128, 0, 0, 0, 0]
    let context = CGContext(data: &data, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

@Test func `按下变暗与系统 Dock 的乘色一致`() throws {
    let result = pixels(try #require(DockPressDarkening.darkened(sample())))
    // 颜色乘 0.4，透明度不变；透明处保持透明。
    let expected: [UInt8] = [80, 40, 20, 255, 40, 20, 8, 128, 0, 0, 0, 0]
    for (value, target) in zip(result, expected) { #expect(abs(Int(value) - Int(target)) <= 1) }
}

@Test func `在已有画面上按下只压暗图标像素`() {
    // 4×1 画布先铺不透明蓝底，图标画在前三格：不透明、半透明、全透明；第四格在图标外。
    var data = [UInt8](repeating: 0, count: 16)
    let context = CGContext(data: &data, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
    let rect = CGRect(x: 0, y: 0, width: 3, height: 1)
    DockPressDarkening.drawPressed(in: context, rect: rect) { context.draw(sample(), in: rect) }
    // 不透明格 = 图标 × 0.4；半透明格 = 图标 × 0.4 叠在蓝底上；透明格和图标外保持蓝底。
    let expected: [UInt8] = [80, 40, 20, 255, 40, 20, 135, 255, 0, 0, 255, 255, 0, 0, 255, 255]
    for (value, target) in zip(data, expected) { #expect(abs(Int(value) - Int(target)) <= 1) }
}
