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
    /// 当前子进程负责的 文件名 → App 路径。
    private var hosted: [String: String] = [:]
    private var plugins: [String: String?] = [:]
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

    func image(for appPath: String) -> NSImage? { images[appPath] }

    /// App 重装或更新后丢掉旧的插件信息与画面；下次 update 重新查插件并重启子进程画新图。
    func forget(appPath: String) {
        plugins[appPath] = nil
        images[appPath] = nil
        hosted = hosted.filter { $0.value != appPath }
    }

    var summary: [String: Any] {
        ["pid": Int(process), "apps": hosted.values.sorted().map { ($0 as NSString).lastPathComponent }, "error": lastError ?? ""]
    }

    /// 应用栏涉及的 App 变化时调用；带插件的集合没变就不动。子进程意外退出（插件崩溃）后不自动重启，
    /// 保留已画好的图标，集合变化时再启动。
    func update(appPaths: [String]) {
        guard let directory else { return }
        var wanted: [String: String] = [:], pairs: [String] = []
        for path in Set(appPaths).sorted() {
            guard let plugin = pluginPath(for: path) else { continue }
            let name = Self.fileName(for: path)
            wanted[name] = path
            pairs.append("\(name)=\(plugin)")
        }
        guard wanted != hosted else { return }
        stop()
        hosted = wanted
        // 先用上次画好的图（立即和原生一致），子进程画出新图后再替换。
        for name in wanted.keys { reload(name: name) }
        guard !pairs.isEmpty, let helper else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        start(helper: helper, arguments: ["--parent-pid", String(getpid()), "--output", directory.path] + pairs)
    }

    func stop() {
        if process > 0 { kill(process, SIGTERM) }
        process = 0
    }

    private func reload(name: String) {
        guard let path = hosted[name], let directory,
              let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else { return }
        image.size = NSSize(width: 128, height: 128)
        images[path] = image
        onChange?(path)
    }

    private func pluginPath(for appPath: String) -> String? {
        if let cached = plugins[appPath] { return cached }
        var result: String?
        if let bundle = Bundle(path: appPath), let name = bundle.object(forInfoDictionaryKey: "NSDockTilePlugIn") as? String,
           let folder = bundle.builtInPlugInsPath {
            let path = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) { result = path }
        }
        plugins[appPath] = result
        return result
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
        let argv: [UnsafeMutablePointer<CChar>?] = ([helper.path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, helper.path, nil, &attributes, argv, environ)
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
