import AppKit
import Foundation

/// 使用本机矢量绘制生成图标，不下载素材，也不修改成员 App 的图标。
@MainActor
func drawDockFoldersIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "DockFoldersIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建图标画布。"])
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor(calibratedRed: 0.38, green: 0.52, blue: 0.64, alpha: 1).setFill()
    base.fill()
    NSGraphicsContext.restoreGraphicsState()

    let upper = NSColor(calibratedRed: 0.55, green: 0.68, blue: 0.77, alpha: 1)
    let lower = NSColor(calibratedRed: 0.34, green: 0.49, blue: 0.61, alpha: 1)
    NSGradient(starting: upper, ending: lower)?.draw(in: base, angle: -90)
    NSColor.white.withAlphaComponent(0.24).setStroke()
    base.lineWidth = 2
    base.stroke()

    // 半透明外轮廓提供文件夹意象；四个白色方块在 16 像素下仍能识别为分组。
    let tab = NSBezierPath(roundedRect: NSRect(x: 244, y: 706, width: 242, height: 76), xRadius: 31, yRadius: 31)
    NSColor.white.withAlphaComponent(0.15).setFill()
    tab.fill()
    let folder = NSBezierPath(roundedRect: NSRect(x: 222, y: 252, width: 580, height: 484), xRadius: 74, yRadius: 74)
    NSColor.white.withAlphaComponent(0.13).setFill()
    folder.fill()
    NSColor.white.withAlphaComponent(0.16).setStroke()
    folder.lineWidth = 2
    folder.stroke()

    for y: CGFloat in [318, 532] {
        for x: CGFloat in [316, 530] {
            NSGraphicsContext.saveGraphicsState()
            let tileShadow = NSShadow()
            tileShadow.shadowColor = NSColor(calibratedWhite: 0.12, alpha: 0.10)
            tileShadow.shadowBlurRadius = 10
            tileShadow.shadowOffset = NSSize(width: 0, height: -5)
            tileShadow.set()
            NSColor(calibratedWhite: 1, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 178, height: 178), xRadius: 36, yRadius: 36).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DockFoldersIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法导出 PNG。"])
    }
    return png
}

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/app-icon", isDirectory: true)
let iconset = destination.appendingPathComponent("DockFolders.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in variants {
    try drawDockFoldersIcon(pixels: pixels).write(to: iconset.appendingPathComponent(name), options: .atomic)
}
let preview = destination.appendingPathComponent("DockFolders-1024.png")
try drawDockFoldersIcon(pixels: 1024).write(to: preview, options: .atomic)
let result = destination.appendingPathComponent("DockFolders.icns")
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", "-o", result.path, iconset.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else {
    throw NSError(domain: "DockFoldersIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil 转换失败。"])
}
print("已生成 10 份标准 iconset PNG，以及 \(result.path)")
