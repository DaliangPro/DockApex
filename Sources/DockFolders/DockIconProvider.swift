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
        let image: NSImage
    }

    private var applications: [String: ApplicationEntry] = [:]
    private var groups: [UUID: GroupEntry] = [:]
    private(set) var statistics = Statistics()

    func icon(for app: AppReference) -> NSImage {
        // App 自带 Dock 图标插件时用插件画出的图标，与原生 Dock 一致（用户在 App 里换过的图标只走这条路）。
        if let image = DockTilePluginService.shared.image(for: app.path) { return image }
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
        statistics.applicationSourceLoads += 1
        trimApplicationsIfNeeded(keeping: app.path)
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
        if let entry = groups[group.id], entry.memberPaths == paths, entry.memberImages == identities {
            statistics.groupCacheHits += 1
            return entry.image
        }
        let memberCount = group.apps.count
        // 绘制闭包只读取已取得的图像，动画重绘时不再枚举进程或重新获取图标来源。
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
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
            return true
        }
        groups[group.id] = GroupEntry(memberPaths: paths, memberImages: identities, image: image)
        statistics.groupSourceLoads += 1
        if groups.count > 128, let current = groups[group.id] { groups = [group.id: current] }
        return image
    }

    /// 应用图标或分组配置有明确变化时使用；不会修改应用包或系统图标缓存。
    func invalidate(appPath: String? = nil) {
        if let appPath { applications[appPath] = nil }
        else { applications.removeAll(keepingCapacity: true) }
        groups.removeAll(keepingCapacity: true)
    }

    private func trimApplicationsIfNeeded(keeping path: String) {
        guard applications.count > 256 else { return }
        let cutoff = ProcessInfo.processInfo.systemUptime - 60
        applications = applications.filter { $0.key == path || $0.value.checkAfter > cutoff }
        if applications.count > 256, let current = applications[path] { applications = [path: current] }
    }
}
