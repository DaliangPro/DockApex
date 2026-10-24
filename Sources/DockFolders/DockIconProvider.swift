import AppKit

/// 保留系统图标的全部分辨率、透明边距和外观变体；不另加底板或裁切。
/// 动画与 draw 回调只读取调用方预取的图像，不在每帧扫描进程。
@MainActor
final class DockIconProvider {
    static let shared = DockIconProvider()

    struct RuntimeAppearance {
        let image: NSImage
        let isRunning: Bool
    }

    struct Statistics {
        var applicationCacheHits = 0
        var applicationSourceLoads = 0
        var groupCacheHits = 0
        var groupSourceLoads = 0
    }

    private struct ApplicationEntry {
        let image: NSImage
        let sourcePID: pid_t?
        var checkAfter: TimeInterval
        let fileSourceLoadedAt: TimeInterval
    }

    private struct GroupEntry {
        let memberPaths: [String]
        let memberImages: [ObjectIdentifier]
        let appearance: NSAppearance.Name?
        let image: NSImage
    }

    private struct MinimizedEntry {
        let source: ObjectIdentifier
        let appearance: NSAppearance.Name?
        let image: NSImage
    }

    private var applications: [String: ApplicationEntry] = [:]
    /// 应用包还在时最后取到的图标；应用包暂时不在时（缓存已因目录变化清掉）用它画“找不到”图标。
    private var lastFound: [String: NSImage] = [:]
    private var broken: [String: (source: ObjectIdentifier, image: NSImage)] = [:]
    /// 原生 Dock 的“找不到”覆盖图：灰色问号，`-[DOCKFileTile convertToBroken]` 以 0.8 不透明度叠在图标上。
    private static let notFoundOverlay = Bundle(path: "/System/Library/CoreServices/Dock.app")?.image(forResource: "notfoundover")
    private var groups: [UUID: GroupEntry] = [:]
    private var minimized: [String: MinimizedEntry] = [:]
    private(set) var statistics = Statistics()

    func icon(for app: AppReference) -> NSImage {
        // App 自带 Dock 图标插件时用插件画出的图标，与原生 Dock 一致（用户在 App 里换过的图标只走这条路）。
        if let image = DockTilePluginService.shared.image(for: app.path) { return image }
        // 应用包暂时不在（更新替换中、被移走或卸载待移除）：照原生 Dock 留着原图标、叠上灰色问号，等它回来或被移除。
        if !FileManager.default.fileExists(atPath: app.path), ShelfRunningApplications.shared.running(app) == nil {
            return brokenIcon(for: app)
        }
        broken[app.path] = nil
        let now = ProcessInfo.processInfo.systemUptime
        if let entry = applications[app.path], now < entry.checkAfter {
            statistics.applicationCacheHits += 1
            return entry.image
        }
        let running = ShelfRunningApplications.shared.running(app)
        let runningImage = running?.icon
        if var entry = applications[app.path], entry.sourcePID == running?.processIdentifier {
            // NSRunningApplication.icon 返回的系统图像可以更新，不能仅按 PID 永久缓存。
            if let runningImage, entry.image === runningImage {
                entry.checkAfter = now + 1
                applications[app.path] = entry
                statistics.applicationCacheHits += 1
                return entry.image
            }
            if runningImage == nil, entry.sourcePID == nil, now - entry.fileSourceLoadedAt < 30 {
                entry.checkAfter = now + 1
                applications[app.path] = entry
                statistics.applicationCacheHits += 1
                return entry.image
            }
        }
        let image = runningImage ?? NSWorkspace.shared.icon(forFile: app.path)
        applications[app.path] = ApplicationEntry(image: image, sourcePID: runningImage == nil ? nil : running?.processIdentifier,
                                                  checkAfter: now + 1, fileSourceLoadedAt: now)
        lastFound[app.path] = image
        statistics.applicationSourceLoads += 1
        trimApplicationsIfNeeded(keeping: app.path)
        return image
    }

    private func brokenIcon(for app: AppReference) -> NSImage {
        let base = lastFound[app.path] ?? applications[app.path]?.image ?? NSWorkspace.shared.icon(forFile: app.path)
        if let entry = broken[app.path], entry.source == ObjectIdentifier(base) { return entry.image }
        let image = Self.bitmapImage(size: NSSize(width: 128, height: 128), appearance: NSApp.effectiveAppearance) { rect in
            base.draw(in: rect)
            Self.notFoundOverlay?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.8)
        }
        broken[app.path] = (ObjectIdentifier(base), image)
        return image
    }

    /// 布局与工作区事件触发时批量取值；绘制过程只使用这份快照。
    func runtimeAppearance(for apps: [AppReference]) -> [String: RuntimeAppearance] {
        var result: [String: RuntimeAppearance] = [:]
        for app in apps {
            result[app.path] = RuntimeAppearance(image: icon(for: app), isRunning: ShelfRunningApplications.shared.running(app) != nil)
        }
        return result
    }

    func groupIcon(for group: AppGroup) -> NSImage {
        let members = Array(group.apps.prefix(9))
        let images = members.map { icon(for: $0) }
        let paths = members.map(\.path)
        let identities = images.map(ObjectIdentifier.init)
        let appearance = NSApp.effectiveAppearance
        let appearanceName = appearance.bestMatch(from: [.aqua, .darkAqua])
        if let entry = groups[group.id], entry.memberPaths == paths, entry.memberImages == identities, entry.appearance == appearanceName {
            statistics.groupCacheHits += 1
            return entry.image
        }
        let memberCount = group.apps.count
        // 一次画成位图：动画按各种尺寸重画时只缩放位图，不再逐个现画成员。成员多是系统图标，现画到新尺寸会同步向
        // IconServices 要图（10-23 实测拖动、建组动画里卡住主线程 150–400 ms，最长一次 3 秒）。底板随深浅色，按外观分别缓存。
        let image = Self.bitmapImage(size: NSSize(width: 128, height: 128), appearance: appearance) { rect in
            // 版式与拖叠建组动画共用（GroupIconGeometry），动画终点与这里画出的图标重合。
            let plate = GroupIconGeometry.plate(in: rect)
            let radius = GroupIconGeometry.cornerRadius(of: plate)
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).stroke()
            for (index, image) in images.enumerated() {
                image.draw(in: GroupIconGeometry.slot(index, memberCount: memberCount, in: rect))
            }
        }
        groups[group.id] = GroupEntry(memberPaths: paths, memberImages: identities, appearance: appearanceName, image: image)
        statistics.groupSourceLoads += 1
        if groups.count > 128, let current = groups[group.id] { groups = [group.id: current] }
        return image
    }

    /// 最小化窗口在应用栏上的图标：窗口样框里放 App 图标。按 App 与外观缓存成位图：原先每次刷新都新建绘制闭包，
    /// 应用栏见到新图像就重新取位图，现画 App 图标还要做色彩转换（10-23 卡顿栈里 10 次共约 0.75 秒）。
    func minimizedWindowIcon(for app: AppReference) -> NSImage {
        let source = icon(for: app)
        let appearance = NSApp.effectiveAppearance
        let appearanceName = appearance.bestMatch(from: [.aqua, .darkAqua])
        if let entry = minimized[app.path], entry.source == ObjectIdentifier(source), entry.appearance == appearanceName { return entry.image }
        let image = Self.bitmapImage(size: NSSize(width: 128, height: 128), appearance: appearance) { rect in
            let frame = rect.insetBy(dx: 5, dy: 12)
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
            NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).stroke()
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: CGRect(x: frame.minX + 1, y: frame.maxY - 18, width: frame.width - 2, height: 1)).fill()
            source.draw(in: CGRect(x: 30, y: 22, width: 68, height: 68))
        }
        if minimized.count >= 64 { minimized.removeAll(keepingCapacity: true) }
        minimized[app.path] = MinimizedEntry(source: ObjectIdentifier(source), appearance: appearanceName, image: image)
        return image
    }

    /// 按指定外观画成 2 倍像素的位图（128 点即 256 像素，够应用栏放大到最大尺寸）。
    static func bitmapImage(size: NSSize, appearance: NSAppearance, draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        // 先定点尺寸再建上下文，上下文才按 2 倍缩放；顺序反了会按像素坐标画，内容只占左下四分之一。
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        appearance.performAsCurrentDrawingAppearance { draw(NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    /// 应用图标或分组配置有明确变化时使用；不会修改应用包或系统图标缓存。
    /// 指定 App 时只重画含它的分组：任何 App 启动、退出都会来这里，原先清空全部分组，每次都把所有分组重画一遍（含色彩转换）。
    /// 其他分组的成员图像换了，groupIcon 也会按图像身份发现。
    func invalidate(appPath: String? = nil) {
        if let appPath {
            applications[appPath] = nil
            groups = groups.filter { !$0.value.memberPaths.contains(appPath) }
        } else {
            applications.removeAll(keepingCapacity: true)
            groups.removeAll(keepingCapacity: true)
        }
    }

    private func trimApplicationsIfNeeded(keeping path: String) {
        guard applications.count > 256 else { return }
        let cutoff = ProcessInfo.processInfo.systemUptime - 60
        applications = applications.filter { $0.key == path || $0.value.checkAfter > cutoff }
        if applications.count > 256, let current = applications[path] { applications = [path: current] }
    }
}
