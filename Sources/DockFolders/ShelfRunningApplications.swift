import AppKit
import Darwin

struct ShelfRunningProcessIdentity: Equatable, Hashable, Sendable {
    let pid: pid_t
    let userID: UInt32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func capture(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return Self(pid: pid, userID: info.pbi_uid, startedSeconds: info.pbi_start_tvsec,
                    startedMicroseconds: info.pbi_start_tvusec)
    }
}

struct ShelfRunningApplicationRecord: Equatable, Sendable {
    let identity: ShelfRunningProcessIdentity
    var reference: AppReference
    var aliases: Set<String>
    var isRegular: Bool
}

/// 纯内存索引：同 Bundle ID 的不同安装路径绝不合并，同路径多实例按出生时间选择。
struct ShelfRunningApplicationIndex {
    private(set) var records: [pid_t: ShelfRunningApplicationRecord] = [:]
    private var paths: [String: Set<pid_t>] = [:]

    mutating func insert(_ record: ShelfRunningApplicationRecord) {
        remove(pid: record.identity.pid)
        records[record.identity.pid] = record
        for path in record.aliases.union([record.reference.path]) { paths[path, default: []].insert(record.identity.pid) }
    }

    mutating func remove(pid: pid_t, matching identity: ShelfRunningProcessIdentity? = nil) {
        guard let old = records[pid], identity == nil || old.identity == identity else { return }
        records[pid] = nil
        for path in old.aliases.union([old.reference.path]) {
            paths[path]?.remove(pid)
            if paths[path]?.isEmpty == true { paths[path] = nil }
        }
    }

    func candidates(path: String) -> [ShelfRunningApplicationRecord] {
        (paths[path] ?? []).compactMap { records[$0] }.sorted {
            if $0.identity.startedSeconds != $1.identity.startedSeconds { return $0.identity.startedSeconds > $1.identity.startedSeconds }
            return $0.identity.startedMicroseconds > $1.identity.startedMicroseconds
        }
    }
}

/// 初始化时建档一次；其后只靠工作区事件维护，不在查询失败时重新扫描全体应用。
@MainActor
final class ShelfRunningApplications {
    static let shared = ShelfRunningApplications()
    var onChange: (() -> Void)?
    /// 退出时还有 Dock 图标的 App（“最近使用”按它记）。
    var onRegularTerminated: ((AppReference) -> Void)?
    private var index = ShelfRunningApplicationIndex()
    private var applications: [pid_t: NSRunningApplication] = [:]
    private var observers: [NSObjectProtocol] = []
    private var policyObservations: [pid_t: NSKeyValueObservation] = [:]
    private var started = false
    private var changeScheduled = false
    private var generation: UInt64 = 0
    private(set) var initialSnapshotCount = 0
    private(set) var metadataBuildCount = 0

    private init() { start() }

    func start() {
        guard !started else { return }
        started = true; generation &+= 1
        let center = NSWorkspace.shared.notificationCenter
        let events = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                      NSWorkspace.didUnhideApplicationNotification]
        for name in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let terminated = note.name == NSWorkspace.didTerminateApplicationNotification
                let refreshMetadata = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if terminated { self.removeTerminated(app.processIdentifier) }
                    else { self.register(app, refreshMetadata: refreshMetadata) }
                    self.scheduleChange()
                }
            })
        }
        // 先安装观察者再取初始清单，避免启动期间漏掉新应用。
        initialSnapshotCount += 1
        for application in NSWorkspace.shared.runningApplications { register(application) }
    }

    func stop() {
        guard started else { return }
        started = false; generation &+= 1; changeScheduled = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        for pid in Array(applications.keys) { setApplication(nil, for: pid) }
        index = ShelfRunningApplicationIndex()
    }

    var regularReferences: [AppReference] {
        let records = index.records.values.filter(\.isRegular).sorted {
            if $0.identity.startedSeconds != $1.identity.startedSeconds { return $0.identity.startedSeconds < $1.identity.startedSeconds }
            return $0.identity.startedMicroseconds < $1.identity.startedMicroseconds
        }
        var seen = Set<String>()
        return records.compactMap { record in
            guard isValid(record), seen.insert(record.reference.path).inserted else { return nil }
            return record.reference
        }
    }

    /// 正在运行、但当前没有 Dock 图标（同一路径没有普通实例）。
    func runsWithoutDockIcon(_ path: String) -> Bool {
        let records = index.candidates(path: path).filter { isValid($0) }
        return !records.isEmpty && !records.contains(where: \.isRegular)
    }

    func running(_ app: AppReference) -> NSRunningApplication? {
        for record in index.candidates(path: app.path) {
            guard isValid(record) else { continue }
            return applications[record.identity.pid]
        }
        // 启动器拉起主程序后自己退出：由主程序代表它（运行指示、点按、窗口列表、菜单都按主程序）。
        guard app.bundleIdentifier != nil else { return nil }
        for record in index.records.values where record.isRegular && app.launches(record.reference) && isValid(record) {
            return applications[record.identity.pid]
        }
        return nil
    }

    func reference(forPID pid: pid_t) -> AppReference? {
        guard let record = index.records[pid], isValid(record) else { return nil }
        return record.reference
    }

    /// 用缓存中的对象和内核出生身份核对，不读取 bundleURL、isTerminated 等 LaunchServices 属性。
    func isCurrent(_ application: NSRunningApplication) -> Bool {
        let pid = application.processIdentifier
        guard applications[pid] === application, let record = index.records[pid] else { return false }
        return isValid(record)
    }

    func register(_ application: NSRunningApplication) { register(application, refreshMetadata: false) }

    private func register(_ application: NSRunningApplication, refreshMetadata: Bool) {
        guard started, let identity = ShelfRunningProcessIdentity.capture(application.processIdentifier) else { return }
        if var record = index.records[identity.pid], record.identity == identity, !refreshMetadata {
            // 事件可能携带另一个 NSRunningApplication 包装对象；已核验实例始终保留。
            if let existing = applications[identity.pid] {
                let regular = existing.activationPolicy == .regular
                if record.isRegular != regular { record.isRegular = regular; index.insert(record); scheduleChange() }
            }
            return
        }
        // 用 PID 取得当前包装对象，拒绝将迟到通知中的旧对象登记到复用的 PID 下。
        guard let current = NSRunningApplication(processIdentifier: identity.pid), !current.isTerminated,
              let url = current.bundleURL, let reference = AppReference(url: url) else { return }
        let regular = current.activationPolicy == .regular
        guard ShelfRunningProcessIdentity.capture(identity.pid) == identity else { return }
        let record = ShelfRunningApplicationRecord(identity: identity, reference: reference,
            aliases: [url.path, url.standardizedFileURL.path, reference.path], isRegular: regular)
        setApplication(current, for: identity.pid)
        index.insert(record); metadataBuildCount += 1; scheduleChange()
    }

    /// 换下或放掉某个 PID 的 App 对象都走这里。App 运行中可以随时藏起或露出 Dock 图标（改激活策略，
    /// 不发工作区通知；如 Clash Verge 启动后即藏），原生 Dock 跟着变，这里监听同一属性（实测改后约 0.05 秒收到）。
    /// 监听不持有对象：必须先撤监听、再放对象。反过来会留下指向已释放对象的监听，系统下次发 App 状态通知时
    /// 就会访问它而崩溃（10-20 三次崩溃都在 runningApplicationNotificationCallback）。
    private func setApplication(_ application: NSRunningApplication?, for pid: pid_t) {
        policyObservations.removeValue(forKey: pid)?.invalidate()
        applications[pid] = application
        guard let application else { return }
        policyObservations[pid] = application.observe(\.activationPolicy) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.policyChanged(pid) } }
        }
    }

    private func policyChanged(_ pid: pid_t) {
        guard var record = index.records[pid], let application = applications[pid] else { return }
        let regular = application.activationPolicy == .regular
        guard record.isRegular != regular else { return }
        record.isRegular = regular; index.insert(record); scheduleChange()
    }

    private func removeTerminated(_ pid: pid_t) {
        guard let record = index.records[pid] else { return }
        // 迟到的旧进程退出通知不能移除当前已经登记的新实例。
        guard ShelfRunningProcessIdentity.capture(pid) != record.identity else { return }
        setApplication(nil, for: pid); index.remove(pid: pid, matching: record.identity); scheduleChange()
        if record.isRegular { onRegularTerminated?(record.reference) }
    }

    private func isValid(_ record: ShelfRunningApplicationRecord) -> Bool {
        guard ShelfRunningProcessIdentity.capture(record.identity.pid) == record.identity else {
            setApplication(nil, for: record.identity.pid)
            index.remove(pid: record.identity.pid, matching: record.identity)
            scheduleChange(); return false
        }
        return applications[record.identity.pid] != nil
    }

    private func scheduleChange() {
        guard started, !changeScheduled else { return }
        changeScheduled = true
        let token = generation
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, started, generation == token else { return }
            changeScheduled = false
            onChange?()
        }
    }
}
