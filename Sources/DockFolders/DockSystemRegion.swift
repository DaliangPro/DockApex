import CoreGraphics
import Darwin
import Foundation

enum DockSystemRegionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// 与本机 WindowServer 的方向值一致；底部、左右均已独立验证 visibleFrame 和恢复。
enum DockSystemRegionEdge: Int32, Sendable {
    case bottom = 2
    case left = 3
    case right = 4
}

/// 完整保存 WindowServer 返回值；空区域也是合法的系统 Dock 状态。
struct DockSystemRegionValue: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var reason: Int32
    var orientation: Int32

    init(rect: CGRect, reason: Int32, orientation: Int32) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
        self.reason = reason; self.orientation = orientation
    }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
    func matches(_ other: Self) -> Bool {
        reason == other.reason && orientation == other.orientation
            && zip([x, y, width, height], [other.x, other.y, other.width, other.height]).allSatisfy { abs($0 - $1) < 0.01 }
    }

    /// AppKit 以主屏左下为原点；WindowServer 以主屏左上为原点，包含负坐标副屏。
    static func bottom(appKitRect: CGRect, primaryHeight: CGFloat) throws -> Self {
        try edge(appKitRect: appKitRect, primaryHeight: primaryHeight, edge: .bottom)
    }

    static func edge(appKitRect: CGRect, primaryHeight: CGFloat, edge: DockSystemRegionEdge) throws -> Self {
        let value = Self(rect: CGRect(x: appKitRect.minX, y: primaryHeight - appKitRect.maxY,
                                     width: appKitRect.width, height: appKitRect.height), reason: 5, orientation: edge.rawValue)
        guard primaryHeight.isFinite, primaryHeight > 0, value.isValid, value.width > 0, value.height > 0 else {
            throw DockSystemRegionError.message("Dock 系统预留区的坐标不正确。")
        }
        return value
    }

    /// 一个全局区域只能登记一个显示器；不把多屏包围矩形当作有效占位。
    static func reservation(screenFrame: CGRect, reservedFrame: CGRect, primaryHeight: CGFloat,
                            edge: DockSystemRegionEdge) throws -> Self {
        guard [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
               reservedFrame.minX, reservedFrame.minY, reservedFrame.width, reservedFrame.height].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > 0, reservedFrame.width > 0, reservedFrame.height > 0 else {
            throw DockSystemRegionError.message("Dock 预留区必须具有有效的屏幕和边缘尺寸。")
        }
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        let fits: Bool
        switch edge {
        case .bottom:
            fits = same(reservedFrame.minY, screenFrame.minY) && same(reservedFrame.minX, screenFrame.minX)
                && same(reservedFrame.width, screenFrame.width) && reservedFrame.height < screenFrame.height * 0.15
        case .left:
            fits = same(reservedFrame.minX, screenFrame.minX) && same(reservedFrame.minY, screenFrame.minY)
                && same(reservedFrame.height, screenFrame.height) && reservedFrame.width < screenFrame.width * 0.15
        case .right:
            fits = same(reservedFrame.maxX, screenFrame.maxX) && same(reservedFrame.minY, screenFrame.minY)
                && same(reservedFrame.height, screenFrame.height) && reservedFrame.width < screenFrame.width * 0.15
        }
        guard fits else { throw DockSystemRegionError.message("Dock 预留区必须属于当前单个显示器的完整边缘。") }
        return try self.edge(appKitRect: reservedFrame, primaryHeight: primaryHeight, edge: edge)
    }
}

protocol DockSystemRegionAccess: AnyObject {
    func read() throws -> DockSystemRegionValue
    func set(_ value: DockSystemRegionValue) throws
}

/// 仅使用本进程自己的普通 SkyLight 连接；不申请 universal owner 或操纵 Dock 连接。
final class DockSystemRegionAPI: DockSystemRegionAccess {
    typealias Connection = @convention(c) () -> Int32
    typealias Getter = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias Setter = @convention(c) (Int32, CGRect, Int32, Int32) -> Int32
    private let handle: UnsafeMutableRawPointer
    private let connection: Int32
    private let getter: Getter
    private let setter: Setter

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
            throw DockSystemRegionError.message("当前系统没有可用的 Dock 区域接口。")
        }
        guard let c = dlsym(handle, "SLSMainConnectionID"), let g = dlsym(handle, "SLSGetDockRectWithOrientation"),
              let s = dlsym(handle, "SLSSetDockRectWithOrientation") else {
            dlclose(handle)
            throw DockSystemRegionError.message("当前系统的 Dock 区域接口不完整。")
        }
        self.handle = handle
        connection = unsafeBitCast(c, to: Connection.self)()
        getter = unsafeBitCast(g, to: Getter.self); setter = unsafeBitCast(s, to: Setter.self)
        guard connection != 0 else { throw DockSystemRegionError.message("无法取得本进程的窗口连接。") }
    }
    deinit { dlclose(handle) }
    func read() throws -> DockSystemRegionValue {
        var rect = CGRect.zero, reason: Int32 = -1, orientation: Int32 = -1
        let status = getter(connection, &rect, &reason, &orientation)
        let value = DockSystemRegionValue(rect: rect, reason: reason, orientation: orientation)
        guard status == 0, value.isValid else { throw DockSystemRegionError.message("系统 Dock 区域读取失败（\(status)）。") }
        return value
    }
    func set(_ value: DockSystemRegionValue) throws {
        guard value.isValid else { throw DockSystemRegionError.message("拒绝写入无效 Dock 区域。") }
        let status = setter(connection, value.rect, value.reason, value.orientation)
        guard status == 0 else { throw DockSystemRegionError.message("系统 Dock 区域登记失败（\(status)）。") }
    }
}

struct DockSystemRegionOwner: Codable, Equatable, Sendable {
    var pid: Int32
    var uid: UInt32
    var seconds: UInt64
    var microseconds: UInt64
    static func capture(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        return Self(pid: pid, uid: info.pbi_uid, seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec))
    }
    var isAlive: Bool { uid == getuid() && Self.capture(pid) == self }
}

struct DockSystemRegionSession: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, active, inactive }
    var version = 1
    var id: UUID
    var owner: DockSystemRegionOwner
    var original: DockSystemRegionValue
    var restoreTarget: DockSystemRegionValue
    var applied: DockSystemRegionValue?
    var pending: DockSystemRegionValue?
    var phase: Phase
    var displayUUID: String?
    var updatedAt: Date
    var restored: Bool?

    func owns(_ current: DockSystemRegionValue) -> Bool {
        pending.map { $0.matches(current) } == true || applied.map { $0.matches(current) } == true
    }
}

enum DockSystemRegionRecovery {
    struct Location: Sendable {
        let directory: URL
        init(dataDirectory: URL) { directory = dataDirectory.appendingPathComponent("DockSystemRegionRecovery", isDirectory: true) }
        var state: URL { directory.appendingPathComponent("session.plist") }
        var lock: URL { directory.appendingPathComponent("session.lock") }
    }
    static func withLock<T>(at location: Location, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(location.lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DockSystemRegionError.message("无法建立系统 Dock 区域恢复锁。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw DockSystemRegionError.message("无法锁定系统 Dock 区域会话。") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
    static func load(_ location: Location) throws -> DockSystemRegionSession {
        let session = try PropertyListDecoder().decode(DockSystemRegionSession.self, from: Data(contentsOf: location.state))
        guard session.version == 1, session.owner.uid == getuid(), session.owner.pid > 1, session.owner.seconds > 0,
              session.owner.microseconds < 1_000_000, session.original.isValid, session.restoreTarget.isValid,
              session.applied?.isValid != false, session.pending?.isValid != false else {
            throw DockSystemRegionError.message("系统 Dock 区域恢复记录校验失败。")
        }
        return session
    }
    static func save(_ session: DockSystemRegionSession, _ location: Location) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(session).write(to: location.state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.state.path)
        let fd = open(location.state.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw DockSystemRegionError.message("无法同步系统 Dock 区域恢复记录。") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DockSystemRegionError.message("系统 Dock 区域恢复记录尚未持久化。") }
    }
    /// 调用方必须持锁。先持久化写入意图，异常退出落在 setter 前后均可条件恢复。
    static func apply(_ value: DockSystemRegionValue, displayUUID: String, session: inout DockSystemRegionSession,
                      location: Location, api: any DockSystemRegionAccess) throws {
        let current = try api.read()
        if !session.owns(current) { session.restoreTarget = current }
        session.pending = value; session.updatedAt = Date(); session.displayUUID = displayUUID
        try save(session, location)
        try api.set(value)
        guard try api.read().matches(value) else { throw DockSystemRegionError.message("系统没有采用预期的 Dock 预留区。") }
        session.applied = value; session.pending = nil; session.phase = .active
        try save(session, location)
    }
    @discardableResult
    static func restoreLocked(_ location: Location, expectedID: UUID, api: any DockSystemRegionAccess) throws -> Bool {
        var session = try load(location)
        guard session.id == expectedID, session.phase != .inactive else { return false }
        let current = try api.read()
        var restored = false
        if session.owns(current) {
            // 再读一次；原生 Dock 若先写回自己的值，绝不覆盖它。
            if session.owns(try api.read()) {
                try api.set(session.restoreTarget)
                guard try api.read().matches(session.restoreTarget) else { throw DockSystemRegionError.message("Dock 预留区恢复后核对失败。") }
                restored = true
            }
        }
        session.phase = .inactive; session.pending = nil; session.updatedAt = Date(); session.restored = restored
        try save(session, location)
        return restored
    }

    /// 只存活于所属主应用会话，不注册任何系统服务。退出事件与控制管道均由内核唤醒。
    static func watch(dataDirectory: URL, expectedID: UUID, owner: DockSystemRegionOwner) throws {
        guard owner.pid == getppid(), owner.isAlive else { throw DockSystemRegionError.message("预留区恢复助手的父进程身份不匹配。") }
        let location = Location(dataDirectory: dataDirectory)
        let valid = try withLock(at: location) {
            let session = try load(location)
            return session.id == expectedID && session.owner == owner && session.phase != .inactive
        }
        guard valid else { throw DockSystemRegionError.message("预留区恢复助手没有匹配的会话。") }
        let api = try DockSystemRegionAPI()
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "io.daliang.dockfolders.region-recovery")
        let processSource = DispatchSource.makeProcessSource(identifier: owner.pid, eventMask: .exit, queue: queue)
        processSource.setEventHandler { semaphore.signal() }
        let inputSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        inputSource.setEventHandler { semaphore.signal() }
        processSource.activate(); inputSource.activate()
        defer { processSource.cancel(); inputSource.cancel() }
        // 捕捉父进程在事件源准备前退出的窄窗口。
        if owner.isAlive {
            signal(SIGPIPE, SIG_IGN)
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            semaphore.wait()
        }
        try withLock(at: location) {
            let session = try load(location)
            guard session.id == expectedID, session.owner == owner else { return }
            try restoreLocked(location, expectedID: expectedID, api: api)
        }
    }
}
