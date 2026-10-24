import AppKit
import Darwin
import Foundation

/// 真实 WindowServer 预留区。单个全局 rect 只登记实际交互的一屏，其余屏由兼容层处理。
@MainActor
final class DockSystemRegionController {
    var onStateChanged: (() -> Void)?
    private struct ReportedState: Equatable {
        var applied: Bool
        var displayUUID: String?
        var area: DockReservedArea?
        var error: String?
    }
    private let location: DockSystemRegionRecovery.Location
    private let dataDirectory: URL
    private let watchdogExecutable: URL
    private var api: DockSystemRegionAPI?
    private var sessionID: UUID?
    private var watchdog: Process?
    private var control: Pipe?
    private var areas: [DockReservedArea] = []
    private var preferredDisplayUUID: String?
    private var observers: [NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var lifecycleRevision: UInt64 = 0
    private var reportedState: ReportedState?
    private var reclaimTimes: [TimeInterval] = []
    private var enabled = false
    private var lastAppliedValue: DockSystemRegionValue?
    private(set) var lastError: String?
    private(set) var activeDisplayUUID: String?
    private(set) var activeReservedArea: DockReservedArea?
    /// 上次进锁核对系统预留区的时刻。刷新应用栏很频繁，每次都同步读 WindowServer 时，它一忙主线程就要等几十到几百毫秒。
    private var lastVerified: TimeInterval = 0
    /// 按最近一次登记的结果判断，不读 WindowServer。
    var isApplied: Bool { activeDisplayUUID != nil && lastAppliedValue != nil }
    /// 实时读一次系统预留区核对，只在明确要诊断时用。
    func verifyApplied() -> Bool {
        guard activeDisplayUUID != nil, let lastAppliedValue, let api, let current = try? api.read() else { return false }
        return current.matches(lastAppliedValue)
    }

    init(dataDirectory: URL, watchdogExecutable: URL) {
        self.dataDirectory = dataDirectory; self.watchdogExecutable = watchdogExecutable
        location = DockSystemRegionRecovery.Location(dataDirectory: dataDirectory)
    }

    @discardableResult
    func start(areas: [DockReservedArea], preferredDisplayUUID: String? = nil) -> Bool {
        if !enabled {
            lifecycleRevision &+= 1
            reportedState = nil
        }
        enabled = true
        installObservers()
        return update(areas: areas, preferredDisplayUUID: preferredDisplayUUID)
    }

    @discardableResult
    func update(areas: [DockReservedArea], preferredDisplayUUID: String? = nil) -> Bool {
        self.areas = areas; self.preferredDisplayUUID = preferredDisplayUUID
        guard enabled else { return false }
        defer { scheduleStateNotification() }
        do {
            guard let area = selectArea(areas, preferredDisplayUUID: preferredDisplayUUID) else {
                let success = releaseRegion()
                if success { lastError = nil }
                return success
            }
            guard let primaryHeight = NSScreen.screens.first?.frame.height else {
                throw DockSystemRegionError.message("当前没有可用显示器。")
            }
            guard NSScreen.screens.contains(where: { DockDisplayDescriptor.uuid(for: $0) == area.displayUUID && $0.frame == area.screenFrame }) else {
                throw DockSystemRegionError.message("Dock 预留区所属的显示器已断开或改变布局。")
            }
            let edge: DockSystemRegionEdge
            switch area.position {
            case .bottom: edge = .bottom
            case .left: edge = .left
            case .right: edge = .right
            }
            let requested = try DockSystemRegionValue.reservation(screenFrame: area.screenFrame, reservedFrame: area.reservedFrame,
                                                                 primaryHeight: primaryHeight, edge: edge)
            // 区域没变且 2 秒内核对过就不再进锁、读 WindowServer；系统 Dock 改写预留区最迟在 2 秒后的下一次刷新时
            // 发现（10 秒定时刷新兜底）。
            let now = ProcessInfo.processInfo.systemUptime
            if requested == lastAppliedValue, activeDisplayUUID == area.displayUUID, sessionID != nil, watchdog?.isRunning == true,
               now - lastVerified < 2 {
                activeReservedArea = area
                return true
            }
            let api = try obtainAPI()
            try ensureSession(api: api)
            guard let id = sessionID else { throw DockSystemRegionError.message("预留区会话没有建立。") }
            try DockSystemRegionRecovery.withLock(at: location) {
                var session = try DockSystemRegionRecovery.load(location)
                guard session.id == id, session.owner.isAlive, watchdog?.isRunning == true else {
                    throw DockSystemRegionError.message("预留区恢复助手已退出，未修改系统区域。")
                }
                let current = try api.read()
                if !current.matches(requested) {
                    if session.phase == .active, !session.owns(current) {
                        let now = ProcessInfo.processInfo.systemUptime
                        reclaimTimes.removeAll { now - $0 > 10 }
                        guard reclaimTimes.count < 3, reclaimTimes.last.map({ now - $0 >= 1 }) != false else {
                            throw DockSystemRegionError.message("系统 Dock 正在更新预留区，已暂停争用并等待下一次屏幕事件。")
                        }
                        reclaimTimes.append(now)
                    }
                    try DockSystemRegionRecovery.apply(requested, displayUUID: area.displayUUID, session: &session, location: location, api: api)
                }
            }
            activeDisplayUUID = area.displayUUID; activeReservedArea = area; lastAppliedValue = requested; lastError = nil
            lastVerified = now
            return true
        } catch {
            activeDisplayUUID = nil; activeReservedArea = nil; lastAppliedValue = nil; lastError = error.localizedDescription
            lastVerified = 0
            NSLog("Dock 系统预留区：%@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func stopAndRestore() -> Bool {
        enabled = false; settleTask?.cancel(); settleTask = nil
        lifecycleRevision &+= 1
        notificationTask?.cancel(); notificationTask = nil; reportedState = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        return releaseRegion()
    }

    private var currentReportedState: ReportedState {
        ReportedState(applied: isApplied, displayUUID: activeDisplayUUID, area: activeReservedArea, error: lastError)
    }

    /// 合并同一轮更新，只在状态变化时异步通知；停止或重启后不投递旧会话回调。
    private func scheduleStateNotification() {
        guard enabled, currentReportedState != reportedState, notificationTask == nil else { return }
        let revision = lifecycleRevision
        notificationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, enabled, lifecycleRevision == revision, !Task.isCancelled else { return }
            notificationTask = nil
            let state = currentReportedState
            guard state != reportedState else { return }
            // 回调前记下已报告值，外部即使同步读取/更新，也不会形成重复通知。
            reportedState = state
            onStateChanged?()
        }
    }

    private func selectArea(_ values: [DockReservedArea], preferredDisplayUUID: String?) -> DockReservedArea? {
        if let preferredDisplayUUID, let area = values.first(where: { $0.displayUUID == preferredDisplayUUID }) { return area }
        let pointer = NSEvent.mouseLocation
        if let area = values.first(where: { $0.screenFrame.contains(pointer) }) { return area }
        if let activeDisplayUUID, let area = values.first(where: { $0.displayUUID == activeDisplayUUID }) { return area }
        return values.sorted { $0.displayUUID < $1.displayUUID }.first
    }

    private func obtainAPI() throws -> DockSystemRegionAPI {
        if let api { return api }
        let value = try DockSystemRegionAPI(); api = value; return value
    }

    private func ensureSession(api: DockSystemRegionAPI) throws {
        if sessionID != nil, watchdog?.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: watchdogExecutable.path), let owner = DockSystemRegionOwner.capture(getpid()) else {
            throw DockSystemRegionError.message("无法验证预留区恢复助手或主进程身份。")
        }
        let id = try DockSystemRegionRecovery.withLock(at: location) {
            if FileManager.default.fileExists(atPath: location.state.path) {
                let previous = try DockSystemRegionRecovery.load(location)
                if previous.phase != .inactive {
                    guard previous.owner == owner || !previous.owner.isAlive else {
                        throw DockSystemRegionError.message("另一个本工具进程仍持有系统预留区。")
                    }
                    try DockSystemRegionRecovery.restoreLocked(location, expectedID: previous.id, api: api)
                }
            }
            let baseline = try api.read(), id = UUID()
            let session = DockSystemRegionSession(id: id, owner: owner, original: baseline, restoreTarget: baseline,
                                                 phase: .prepared, updatedAt: Date())
            try DockSystemRegionRecovery.save(session, location)
            return id
        }
        sessionID = id
        let process = Process(), input = Pipe(), ready = Pipe()
        process.executableURL = watchdogExecutable
        process.arguments = ["--watch-region", "--data-directory", dataDirectory.path, "--session", id.uuidString,
                             "--owner", try JSONEncoder().encode(owner).base64EncodedString()]
        process.standardInput = input; process.standardOutput = ready; process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close(); try? ready.fileHandleForWriting.close()
        defer { try? ready.fileHandleForReading.close() }
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        guard poll(&descriptor, 1, 1_000) > 0, let data = try ready.fileHandleForReading.read(upToCount: 6),
              data == Data("READY\n".utf8), process.isRunning else {
            try? input.fileHandleForWriting.close()
            throw DockSystemRegionError.message("预留区恢复助手未通过握手，未写入系统区域。")
        }
        watchdog = process; control = input
    }

    private func releaseRegion() -> Bool {
        defer {
            // EOF 唤醒助手再次条件核对；不直接 terminate，保证异常路径仍能恢复。
            try? control?.fileHandleForWriting.close(); control = nil; watchdog = nil
            sessionID = nil; activeDisplayUUID = nil; activeReservedArea = nil; lastAppliedValue = nil
        }
        guard let id = sessionID else { return true }
        do {
            let api = try obtainAPI()
            _ = try DockSystemRegionRecovery.withLock(at: location) { try DockSystemRegionRecovery.restoreLocked(location, expectedID: id, api: api) }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            NSLog("Dock 系统预留区恢复：%@", error.localizedDescription)
            return false
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didLaunchApplicationNotification,
                   (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier != "com.apple.dock" { return }
                Task { @MainActor [weak self] in self?.scheduleRecheck() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRecheck() }
        })
    }
    private func scheduleRecheck() {
        guard enabled else { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, enabled, !Task.isCancelled else { return }
            settleTask = nil
            update(areas: areas, preferredDisplayUUID: preferredDisplayUUID)
        }
    }
}
