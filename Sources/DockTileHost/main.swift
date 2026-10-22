import AppKit

/// 代原生 Dock 运行 App 自带的 Dock 图标插件（NSDockTilePlugIn），把它画出的图标存成 PNG 交给应用栏。
/// 用户在 App 里换过的图标（如 Ghostty 自定义图标、Codex 图标偏好）只经由插件画给 Dock，普通取图标接口拿到的是默认图标。
/// 由主程序以“自己负责权限”的方式启动：插件代码拿不到主程序的辅助功能、屏幕录制等授权；崩溃也不影响应用栏。
/// 用法：DockTileHost --parent-pid <pid> --output <目录> <文件名>=<插件路径> …；文件名由主程序按 App 定好，主程序退出后自行结束。

/// 交给插件的替身图块：插件设置内容视图并调用 display()，这里把内容视图渲染成图片。
@objc final class StandInDockTile: NSObject {
    @objc var contentView: NSView?
    @objc var showsApplicationBadge = false
    @objc var badgeLabel: String?
    @objc var size: NSSize { NSSize(width: 128, height: 128) }
    @objc var owner: Any? { nil }
    var onDisplay: (() -> Void)?
    @objc func display() { onDisplay?() }
}

@MainActor
final class TileHost {
    private let output: URL
    private var tiles: [StandInDockTile] = []
    private var plugins: [NSObject] = []
    private var written: [String: Data] = [:]

    init(output: URL) { self.output = output }

    func load(name: String, pluginPath: String) {
        guard let bundle = Bundle(path: pluginPath), bundle.load(), let type = bundle.principalClass as? NSObject.Type else {
            FileHandle.standardError.write(Data("加载失败：\(pluginPath)\n".utf8))
            return
        }
        let plugin = type.init()
        let tile = StandInDockTile()
        tile.onDisplay = { [weak self, weak tile] in
            MainActor.assumeIsolated { if let view = tile?.contentView { self?.write(view, name: name) } }
        }
        tiles.append(tile)
        plugins.append(plugin)
        plugin.perform(NSSelectorFromString("setDockTile:"), with: tile)
        if let view = tile.contentView { write(view, name: name) }
    }

    /// 内容不变时不重写、不通知。
    private func write(_ view: NSView, name: String) {
        view.frame = NSRect(x: 0, y: 0, width: 256, height: 256)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), written[name] != data else { return }
        written[name] = data
        do { try data.write(to: output.appendingPathComponent(name), options: .atomic) } catch { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.daliang.dockfolders.dock-tile-updated"), object: name, userInfo: nil, deliverImmediately: true)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4, arguments[0] == "--parent-pid", let parent = Int32(arguments[1]), arguments[2] == "--output" else {
    FileHandle.standardError.write(Data("用法：DockTileHost --parent-pid <pid> --output <目录> <文件名>=<插件路径> …\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// 主程序结束就退出，不留常驻进程。
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { exit(0) }
parentWatch.resume()
if kill(parent, 0) != 0 { exit(0) }

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    let host = TileHost(output: output)
    for pair in arguments.dropFirst(4) {
        guard let separator = pair.range(of: "=") else { continue }
        host.load(name: String(pair[..<separator.lowerBound]), pluginPath: String(pair[separator.upperBound...]))
    }
    // 插件靠通知得知用户换了图标后再画；保持运行以接收。
    withExtendedLifetime(host) { application.run() }
}
