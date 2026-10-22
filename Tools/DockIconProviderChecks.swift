import AppKit
import CryptoKit

/// 只读应用图标检查，不读取或捕获任何用户窗口。
@main
@MainActor
struct DockIconProviderChecks {
    static func main() throws {
        _ = NSApplication.shared
        let provider = DockIconProvider()
        let paths = ["/System/Library/CoreServices/Finder.app", "/System/Applications/Notes.app",
                     "/Applications/Tabbit.app", "/Applications/WeChat.app", NSHomeDirectory() + "/Applications/WeChat-Second.app"]
        let apps = paths.compactMap { AppReference(url: URL(fileURLWithPath: $0)) }
        var checks = 0
        var comparison: [[String: Any]] = []
        for app in apps {
            let image = provider.icon(for: app)
            let source = ShelfRunningApplications.shared.running(app)?.icon ?? NSWorkspace.shared.icon(forFile: app.path)
            precondition(provider.icon(for: app) === image, "同一来源应复用图像")
            checks += 1
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: appearanceName) else { continue }
                let expected = pixels(source, appearance: appearance)
                let actual = pixels(image, appearance: appearance)
                precondition(expected == actual, "缓存必须保留系统图标的外观和透明边距")
                checks += 1
                comparison.append(["application": app.name, "appearance": appearanceName.rawValue,
                                   "samePixelsAsSystemSource": true,
                                   "sha256": SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()])
            }
        }
        let group = AppGroup(id: UUID(), name: "图标缓存检查", apps: Array(apps.prefix(3)))
        let firstGroup = provider.groupIcon(for: group)
        precondition(provider.groupIcon(for: group) === firstGroup, "成员不变应复用缩略图")
        var reordered = group
        reordered.apps.reverse()
        precondition(provider.groupIcon(for: reordered) !== firstGroup, "成员排序改变后应更新缩略图")
        checks += 2
        let start = ContinuousClock.now
        for _ in 0..<1_000 {
            for app in apps { _ = provider.icon(for: app) }
        }
        let duration = start.duration(to: .now).components
        let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
        precondition(provider.statistics.applicationSourceLoads == apps.count, "稳定缓存不得重复取得图标来源")
        checks += 1
        let beforeSnapshot = provider.statistics.applicationSourceLoads
        let appearances = provider.runtimeAppearance(for: apps)
        precondition(appearances.count == apps.count, "批量运行态快照必须涵盖所有应用")
        precondition(provider.statistics.applicationSourceLoads == beforeSnapshot, "读取运行态快照不能重复载入稳定图标")
        checks += 2
        if let first = apps.first {
            let untouched = apps.dropFirst().map { ($0.path, provider.icon(for: $0)) }
            provider.invalidate(appPath: first.path)
            _ = provider.icon(for: first)
            precondition(provider.statistics.applicationSourceLoads == beforeSnapshot + 1, "明确路径变化应立即重取该图标")
            for (path, image) in untouched {
                guard let app = apps.first(where: { $0.path == path }) else { continue }
                precondition(provider.icon(for: app) === image, "路径失效不能清空其他应用的缓存")
            }
            checks += 2
        }
        let report: [String: Any] = ["checksPassed": checks, "applications": apps.count,
                                    "cachedRequests": apps.count * 1_000, "cachedMilliseconds": elapsed,
                                    "sourceLoads": provider.statistics.applicationSourceLoads,
                                    "cacheHits": provider.statistics.applicationCacheHits,
                                    "comparisons": comparison]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = CommandLine.arguments.dropFirst().first {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func pixels(_ image: NSImage, appearance: NSAppearance) -> Data {
        let size = 108
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: size * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else {
            preconditionFailure("无法创建图标检查画布")
        }
        memset(bytes, 0, bitmap.bytesPerRow * size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero,
                       operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: bytes, count: bitmap.bytesPerRow * size)
    }
}
