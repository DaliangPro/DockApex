import AppKit
import CryptoKit
import Darwin

/// 让应用栏的图标与原生 Dock 一致：App 自带 Dock 图标插件（Info.plist 的 NSDockTilePlugIn）时，
/// 用插件画出的图标。用户在 App 里换过的图标（如 Ghostty 自定义图标、Codex 图标偏好）只经由插件画给 Dock，
/// 普通取图标接口拿到的是默认图标。插件由子进程 DockTileHost 运行并存成 PNG：
/// 子进程以“自己负责权限”的方式启动，插件代码拿不到本应用的辅助功能、屏幕录制等授权；崩溃也不影响应用栏。
@MainActor
final class DockTilePluginService {
    static let shared = DockTilePluginService()

    /// 某个 App 的插件图标有了新画面（参数为 App 路径）。
    var onChange: ((String) -> Void)?
    private var directory: URL?
    private var helper: URL?
    private var process: pid_t = 0
    /// 每个子进程结束时回收（含被替换掉的旧进程），避免留下僵尸进程。
    private var exitWatches: [pid_t: DispatchSourceProcess] = [:]
    private struct HostedPlugin: Equatable {
        let app: String
        let plugin: String
        let stamp: String
    }
    /// 当前子进程加载的 文件名 → App、插件路径与本体标记。只增不减：App 退出或移出应用栏后插件留在子进程里，
    /// 再出现时不必重启。集合一变就整体重启会重载全部插件，Ghostty 的插件每次加载都改写 App 包里的图标
    /// （10-23 实测打开、关闭“系统设置”各重启一次）。
    private var hosted: [String: HostedPlugin] = [:]
    /// 当前显示需要的 App；只有它们用插件画的图标，移出应用栏、更新后没了插件的 App 改回普通图标。
    private var shownApps: Set<String> = []
    /// App 路径 → 插件路径与本体标记（缓存 nil 表示没有插件）。
    private var plugins: [String: (path: String, stamp: String)?] = [:]
    private var images: [String: NSImage] = [:]
    private var observer: NSObjectProtocol?
    private(set) var lastError: String?

    func configure(directory: URL, helper: URL) {
        self.directory = directory
        self.helper = helper
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.daliang.dockfolders.dock-tile-updated"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String
            MainActor.assumeIsolated { if let name { self?.reload(name: name) } }
        }
    }

    func image(for appPath: String) -> NSImage? { shownApps.contains(appPath) ? images[appPath] : nil }

    /// App 包里有文件变化后重新查插件；插件本体真的换了（重装、更新），下次 update 才重启子进程画新图。
    /// 只改 Finder 自定义图标不算：Ghostty 的插件每次加载都会改 App 包里的图标文件，
    /// 若因此重启子进程，插件又会再改一次，循环不止并连带系统反复登记该 App。
    func forget(appPath: String) {
        plugins[appPath] = nil
    }

    var summary: [String: Any] {
        ["pid": Int(process), "apps": hosted.values.map { ($0.app as NSString).lastPathComponent }.sorted(),
         "shown": shownApps.count, "error": lastError ?? ""]
    }

    /// 应用栏涉及的 App 变化时调用；需要的插件都已加载、本体没换就不动。子进程意外退出（插件崩溃）后不自动重启，
    /// 保留已画好的图标，需要新插件时再启动。
    func update(appPaths: [String]) {
        guard let directory else { return }
        var wanted: [String: HostedPlugin] = [:]
        for path in Set(appPaths) {
            guard let plugin = plugin(for: path) else { continue }
            wanted[Self.fileName(for: path)] = HostedPlugin(app: path, plugin: plugin.path, stamp: plugin.stamp)
        }
        shownApps = Set(wanted.values.map(\.app))
        guard wanted.contains(where: { hosted[$0.key] != $0.value }) else { return }
        stop()
        hosted.merge(wanted) { $1 }
        // 先用上次画好的图（立即和原生一致），子进程画出新图后再替换。
        for name in wanted.keys { reload(name: name) }
        guard let helper else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pairs = hosted.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.plugin)" }
        start(helper: helper, arguments: ["--parent-pid", String(getpid()), "--output", directory.path] + pairs)
    }

    func stop() {
        if process > 0 { kill(process, SIGTERM) }
        process = 0
    }

    private func reload(name: String) {
        guard let path = hosted[name]?.app, let directory,
              let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else { return }
        image.size = NSSize(width: 128, height: 128)
        images[path] = image
        // 不在显示的插件（如退出了的“时钟”每分钟重画）只更新留存的画面，不刷新应用栏。
        if shownApps.contains(path) { onChange?(path) }
    }

    private func plugin(for appPath: String) -> (path: String, stamp: String)? {
        if let cached = plugins[appPath] { return cached }
        var result: (path: String, stamp: String)?
        if let bundle = Bundle(path: appPath), let name = bundle.object(forInfoDictionaryKey: "NSDockTilePlugIn") as? String,
           let folder = bundle.builtInPlugInsPath {
            let path = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) { result = (path, Self.stamp(ofPlugin: path)) }
        }
        plugins[appPath] = result
        return result
    }

    /// 插件本体标记：可执行文件的 inode 与修改时间，只在重装、更新换掉插件时变。直接读 Info.plist，Bundle 会缓存旧内容。
    private static func stamp(ofPlugin path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as? [String: Any]
        let executable = (info?["CFBundleExecutable"] as? String).map { url.appendingPathComponent("Contents/MacOS/" + $0).path } ?? path
        var status = stat()
        guard stat(executable, &status) == 0 else { return "" }
        return "\(status.st_ino):\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
    }

    /// 子进程自己负责权限（与终端类 App 启动子程序的做法相同）：拿不到这个开关就不运行插件。
    private func start(helper: URL, arguments: [String]) {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else {
            lastError = "系统不支持子进程自负权限，未运行 Dock 图标插件。"
            return
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        guard unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1) == 0 else {
            lastError = "无法设置子进程自负权限，未运行 Dock 图标插件。"
            return
        }
        // 子进程只拿到下面显式打开的 0、1、2：主程序的其他描述符不能落到第三方插件手里。10-23 实测子进程带走了
        // 预留区守护进程的控制管道，主程序关掉自己那端后守护进程收不到结束信号，一直滞留到子进程退出。
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([helper.path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, helper.path, &actions, &attributes, argv, environ)
        guard result == 0 else { lastError = "Dock 图标插件子进程启动失败（\(result)）。"; return }
        process = pid
        lastError = nil
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                waitpid(pid, nil, WNOHANG)
                if self?.process == pid { self?.process = 0; self?.lastError = "Dock 图标插件子进程已退出。" }
                self?.exitWatches.removeValue(forKey: pid)?.cancel()
            }
        }
        watch.resume()
        exitWatches[pid] = watch
    }

    static func fileName(for appPath: String) -> String {
        SHA256.hash(data: Data(appPath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24) + ".png"
    }
}
