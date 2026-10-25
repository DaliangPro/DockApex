import Foundation

/// 系统设置里改程序坞的大小、放大（及放大尺寸）、运行指示、启动动画、“把窗口最小化为应用程序图标”时，应用栏跟着变。
/// 除大小外，这几项本应用不写系统 Dock 偏好（经典模式只改自动隐藏、弹出延迟和图标尺寸），值就是用户在系统设置里选的；
/// 大小会被本应用拿去对准最小化落点，是否用户改的由调用方判断。
/// 值直接向系统 Dock 读（CoreDock），只有运行指示没有读取接口，从偏好文件读：系统 Dock 改了设置要过约 5 秒才写进
/// 偏好文件（10-25 实测拖完放大滑块 6 秒应用栏才跟上），只看文件就跟不上。偏好文件变了、或系统设置在前台时每 0.2 秒，
/// 读一次、和上次比，有变化才回调；启动时先回调一次当前值。影子 Dock 会改写放大，那时是否跟随也由调用方判断。
final class NativeDockSettingsWatcher: @unchecked Sendable {
    struct Values: Equatable, Sendable {
        var magnification: Bool
        var largeSize: Double
        var showRunningIndicators: Bool
        var animateLaunching: Bool
        var minimizeToApplication: Bool
        /// 系统 Dock 当前的图标尺寸（点）；读不到为 nil。
        var tileSize: Double?
    }

    private let queue = DispatchQueue(label: "io.daliang.dockfolders.dock-settings", qos: .utility)
    private let path: String
    private let readsDock: Bool
    private let onChange: @Sendable (Values) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var liveTimer: DispatchSourceTimer?
    private var last: Values?

    /// 离线检查换成临时文件，并且不向系统 Dock 读（readsDock 为 false）。
    init(path: String = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist", readsDock: Bool = true,
         onChange: @escaping @Sendable (Values) -> Void) {
        self.path = path
        self.readsDock = readsDock
        self.onChange = onChange
    }

    func start() { queue.async { self.reload(); self.arm() } }

    /// 系统设置在前台时打开：拖滑块期间每 0.2 秒读一次，应用栏跟着实时变。
    func setLive(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if on, self.liveTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 0.2)
                timer.setEventHandler { [weak self] in self?.reload() }
                timer.resume()
                self.liveTimer = timer
            } else if !on {
                self.liveTimer?.cancel(); self.liveTimer = nil
            }
        }
    }

    /// 默认值与 AppController.nativeOptions 一致。
    static func read(path: String, readsDock: Bool) -> Values {
        let preferences = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil)) as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { preferences[key] }
        var values = Values(magnification: (value("magnification") as? Bool) ?? false,
                            largeSize: min(128, max(32, (value("largesize") as? Double) ?? 64)),
                            showRunningIndicators: (value("show-process-indicators") as? Bool) ?? true,
                            animateLaunching: (value("launchanim") as? Bool) ?? true,
                            minimizeToApplication: (value("minimize-to-application") as? Bool) ?? false,
                            tileSize: value("tilesize") as? Double)
        if readsDock, let live = CoreDockSettings.read() {
            values.magnification = live.magnification
            values.largeSize = min(128, max(32, live.largeSize))
            values.animateLaunching = live.animateLaunching
            values.minimizeToApplication = live.minimizeToApplication
            values.tileSize = live.tileSize
        }
        return values
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
        let values = Self.read(path: path, readsDock: readsDock)
        guard values != last else { return }
        last = values
        onChange(values)
    }
}

/// 系统 Dock 设置的即时读取：CoreDock 私有接口（系统设置里的滑块和开关同样经它改），不重启 Dock。
/// 放大尺寸与图标尺寸一样取值为 (尺寸 - 16) / 112。缺任何一个接口就返回 nil，改用偏好文件。
private enum CoreDockSettings {
    private typealias FloatGetter = @convention(c) () -> Float
    private typealias BoolGetter = @convention(c) () -> UInt8

    static func read() -> (magnification: Bool, largeSize: Double, animateLaunching: Bool, minimizeToApplication: Bool, tileSize: Double)? {
        let handle = dlopen(nil, RTLD_NOW)
        guard let tile = dlsym(handle, "CoreDockGetTileSize"), let magnificationSize = dlsym(handle, "CoreDockGetMagnificationSize"),
              let magnification = dlsym(handle, "CoreDockIsMagnificationEnabled"),
              let launch = dlsym(handle, "CoreDockIsLaunchAnimationsEnabled"), let inPlace = dlsym(handle, "CoreDockGetMinimizeInPlace") else { return nil }
        return (unsafeBitCast(magnification, to: BoolGetter.self)() != 0,
                (16 + Double(unsafeBitCast(magnificationSize, to: FloatGetter.self)()) * 112).rounded(),
                unsafeBitCast(launch, to: BoolGetter.self)() != 0,
                unsafeBitCast(inPlace, to: BoolGetter.self)() != 0,
                (16 + Double(unsafeBitCast(tile, to: FloatGetter.self)()) * 112).rounded())
    }
}

/// 系统 Dock 放大的即时写入（CoreDock 私有接口，系统设置里的“放大”滑块同样经它改），不重启 Dock。
/// 设置菜单里的“放大”滑块写给系统 Dock，跟随系统设置时读回来的就是同样的值，两边不会互相改回去。
enum CoreDockMagnification {
    private typealias BoolSetter = @convention(c) (UInt8) -> Void
    private typealias FloatSetter = @convention(c) (Float) -> Void

    static func set(enabled: Bool, size: Double) {
        let handle = dlopen(nil, RTLD_NOW)
        if let symbol = dlsym(handle, "CoreDockSetMagnificationEnabled") { unsafeBitCast(symbol, to: BoolSetter.self)(enabled ? 1 : 0) }
        if enabled, let symbol = dlsym(handle, "CoreDockSetMagnificationSize") {
            unsafeBitCast(symbol, to: FloatSetter.self)(Float((min(max(size, 16), 128) - 16 + 0.01) / 112))
        }
    }
}
