import Foundation

/// 系统设置里改程序坞的放大（及放大尺寸）、运行指示、启动动画、“把窗口最小化为应用程序图标”时，应用栏跟着变。
/// 这几项本应用不写系统 Dock 偏好（经典模式只改自动隐藏、弹出延迟和图标尺寸），所以偏好里的值就是用户在系统设置里选的。
/// 监视偏好文件，变了在后台直接读文件里这几项、和上次比，有变化才回调；启动时先回调一次当前值。
/// 影子 Dock 会改写放大，退出时也会写回原值，那些时候是否跟随由调用方判断。
final class NativeDockSettingsWatcher: @unchecked Sendable {
    struct Values: Equatable, Sendable {
        var magnification: Bool
        var largeSize: Double
        var showRunningIndicators: Bool
        var animateLaunching: Bool
        var minimizeToApplication: Bool
    }

    private let queue = DispatchQueue(label: "io.daliang.dockfolders.dock-settings", qos: .utility)
    private let path: String
    private let onChange: @Sendable (Values) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var last: Values?

    /// path 只在离线检查里换成临时文件。
    init(path: String = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist", onChange: @escaping @Sendable (Values) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { queue.async { self.reload(); self.arm() } }

    /// 默认值与 AppController.nativeOptions 一致。直接读文件：文件变了才来读，读的就是这次写下的值，
    /// 也不用每次向 cfprefsd 同步。
    static func read(path: String) -> Values {
        let preferences = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil)) as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { preferences[key] }
        return Values(magnification: (value("magnification") as? Bool) ?? false,
                      largeSize: min(128, max(32, (value("largesize") as? Double) ?? 64)),
                      showRunningIndicators: (value("show-process-indicators") as? Bool) ?? true,
                      animateLaunching: (value("launchanim") as? Bool) ?? true,
                      minimizeToApplication: (value("minimize-to-application") as? Bool) ?? false)
    }

    /// 偏好由 cfprefsd 用改名的方式整份写入，文件换了就要重新挂监视；文件暂时不在时过 2 秒再试。
    private func arm() {
        source?.cancel(); source = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .attrib, .rename, .delete, .link], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.changed(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func changed(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.rename, .delete]) { arm() }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reload() {
        let values = Self.read(path: path)
        guard values != last else { return }
        last = values
        onChange(values)
    }
}
