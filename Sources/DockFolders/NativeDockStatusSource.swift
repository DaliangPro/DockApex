import AppKit
import ApplicationServices
import Darwin

/// PID 与开始时间一起校验，避免 Dock 重启或 PID 复用后保留旧 AX 句柄。
struct NativeDockStatusProcess: Equatable, Sendable {
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static let executablePath = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

    static func capture(_ pid: pid_t, requiresDockPath: Bool = true) -> Self? {
        var info = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length,
              info.pbi_uid == getuid() else { return nil }
        if requiresDockPath {
            var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard count > 0, String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) == executablePath else { return nil }
        }
        return Self(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    static func currentUserPIDs() -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let count = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count) / MemoryLayout<pid_t>.size).filter { $0 > 0 })
    }
}

/// 通常只核对已缓存的 Dock 身份；失效后才列出本用户 PID，全程不请求 LaunchServices。
struct NativeDockStatusProcessResolver {
    private let processList: () -> [pid_t]
    private let capture: (pid_t) -> NativeDockStatusProcess?
    private var cached: NativeDockStatusProcess?

    init(processList: @escaping () -> [pid_t] = NativeDockStatusProcess.currentUserPIDs,
         capture: @escaping (pid_t) -> NativeDockStatusProcess? = { NativeDockStatusProcess.capture($0) }) {
        self.processList = processList; self.capture = capture
    }

    mutating func resolve() -> NativeDockStatusProcess? {
        if let cached, capture(cached.pid) == cached { return cached }
        cached = nil
        for pid in processList() {
            if let process = capture(pid) { cached = process; return process }
        }
        return nil
    }
}

struct NativeDockItemStatus: Equatable, Sendable {
    let badge: String?
    /// AXProgressValue 原始值；不把未知范围擅自转换为百分比。
    let progress: Double?
}

/// AX 的“没有角标”与通信失败是两种状态；失败不能把已知未读数清成空白。
enum NativeDockStatusValue {
    static func isReadFailure(_ value: Any) -> Bool {
        let object = value as AnyObject
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return false }
        let axValue = object as! AXValue
        guard AXValueGetType(axValue) == .axError else { return false }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else { return true }
        return error != .success && error != .noValue && error != .attributeUnsupported
    }

    static func decode(label: Any, progress: Any) -> NativeDockItemStatus? {
        guard !isReadFailure(label), !isReadFailure(progress) else { return nil }
        let text = (label as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = (progress as? NSNumber)?.doubleValue
        return NativeDockItemStatus(badge: text.flatMap { $0.isEmpty ? nil : $0 },
                                    progress: number.flatMap { $0.isFinite ? $0 : nil })
    }
}

struct NativeDockStatusSample: Sendable {
    enum Outcome: String, Sendable { case values, permissionDenied, temporarilyUnavailable }
    let sequence: Int
    let processIdentifier: pid_t
    let durationMilliseconds: Double
    let itemCount: Int
    let outcome: Outcome
}

private enum NativeDockStatusRead: Sendable {
    case values([String: NativeDockItemStatus])
    case permissionDenied
    case temporarilyUnavailable
}

private struct NativeDockStatusResult: Sendable {
    let process: NativeDockStatusProcess?
    let result: NativeDockStatusRead
}

/// 只读系统 Dock 的项目状态，不请求展示菜单、不执行 AX 动作、不读取窗口标题。
private actor NativeDockStatusReader {
    private var process: NativeDockStatusProcess?
    private var application: AXUIElement?
    private var resolver = NativeDockStatusProcessResolver()

    func read(injectedPID: pid_t?, usesInjectedPID: Bool) -> NativeDockStatusResult {
        let selected = usesInjectedPID
            ? injectedPID.flatMap { NativeDockStatusProcess.capture($0, requiresDockPath: false) }
            : resolver.resolve()
        guard let selected else {
            application = nil; process = nil
            return NativeDockStatusResult(process: nil, result: .temporarilyUnavailable)
        }
        let result = read(selected)
        let current = NativeDockStatusProcess.capture(selected.pid, requiresDockPath: !usesInjectedPID)
        // AX 调用期间 Dock 也可能退出；该轮结果不得发布为新实例的角标。
        return NativeDockStatusResult(process: current == selected ? selected : nil,
                                      result: current == selected ? result : .temporarilyUnavailable)
    }

    private func read(_ selected: NativeDockStatusProcess) -> NativeDockStatusRead {
        guard AXIsProcessTrusted() else {
            application = nil
            process = nil
            return .permissionDenied
        }
        if process != selected || application == nil {
            process = selected
            application = AXUIElementCreateApplication(selected.pid)
        }
        guard let application else { return .temporarilyUnavailable }
        AXUIElementSetMessagingTimeout(application, 0.12)
        let deadline = Date().addingTimeInterval(0.6)
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var cursor = 0
        var statuses: [String: NativeDockItemStatus] = [:]
        var readAnyContainer = false
        var incomplete = false
        let itemAttributes = [kAXURLAttribute, "AXStatusLabel", "AXProgressValue"] as CFArray
        while cursor < queue.count, cursor < 256, Date() < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.12)
            guard let role = attribute(element, kAXRoleAttribute) as? String else { incomplete = true; continue }
            if role == "AXDockItem" {
                var rawValues: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(element, itemAttributes, [], &rawValues) == .success,
                      let values = rawValues as? [Any], values.count == 3 else { incomplete = true; continue }
                guard !NativeDockStatusValue.isReadFailure(values[0]) else { incomplete = true; continue }
                guard let path = applicationPath(values[0]) else { continue }
                guard let status = NativeDockStatusValue.decode(label: values[1], progress: values[2]) else {
                    incomplete = true; continue
                }
                if statuses[path] == nil || status.badge != nil || status.progress != nil { statuses[path] = status }
                continue
            }
            // 只穿过 Dock 项目的容器。打开的菜单、应用窗口和其他 AX 内容不进入遍历。
            guard depth < 4, ["AXApplication", "AXList", "AXGroup", "AXScrollArea"].contains(role) else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let elements = children as? [AXUIElement] {
                readAnyContainer = true
                if elements.count > 256 - min(256, queue.count) { incomplete = true }
                queue.append(contentsOf: elements.prefix(256 - min(256, queue.count)).map { ($0, depth + 1) })
            } else { incomplete = true }
        }
        if Date() >= deadline { return .temporarilyUnavailable }
        return readAnyContainer && !incomplete ? .values(statuses) : .temporarilyUnavailable
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func applicationPath(_ value: Any) -> String? {
        let url: URL?
        if let direct = value as? URL { url = direct }
        else if let string = value as? String { url = string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string) }
        else { url = nil }
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

@MainActor
final class NativeDockStatusSource {
    private let onChanged: ([String: NativeDockItemStatus]) -> Void
    private let reader = NativeDockStatusReader()
    private let processIdentifierProvider: (() -> pid_t?)?
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var generation = 0
    private var dockProcess: NativeDockStatusProcess?
    private var latest: [String: NativeDockItemStatus] = [:]
    private var lastSuccess: Date?
    /// 用于独立只读检查；不包含应用名称、窗口标题或角标内容。
    private(set) var lastSample: NativeDockStatusSample?

    init(onChanged: @escaping ([String: NativeDockItemStatus]) -> Void, processIdentifierProvider: (() -> pid_t?)? = nil) {
        self.onChanged = onChanged
        self.processIdentifierProvider = processIdentifierProvider
    }

    func start() {
        guard timer == nil else { return }
        generation += 1
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        inFlight?.cancel()
        inFlight = nil
        dockProcess = nil
        lastSuccess = nil
        publish([:])
    }

    private func poll() {
        guard timer != nil, inFlight == nil else { return }
        let injectedPID = processIdentifierProvider?()
        let usesInjectedPID = processIdentifierProvider != nil
        let token = generation
        inFlight = Task { [weak self, reader] in
            guard !Task.isCancelled else { return }
            let start = ContinuousClock.now
            let reading = await reader.read(injectedPID: injectedPID, usesInjectedPID: usesInjectedPID)
            guard let self, token == generation, !Task.isCancelled else { return }
            inFlight = nil
            guard let process = reading.process else {
                dockProcess = nil; lastSuccess = nil; publish([:]); return
            }
            if dockProcess != process { dockProcess = process; lastSuccess = nil; publish([:]) }
            let pid = process.pid
            let elapsed = start.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            let sequence = (lastSample?.sequence ?? 0) + 1
            switch reading.result {
            case .values(let statuses):
                lastSample = NativeDockStatusSample(sequence: sequence, processIdentifier: pid, durationMilliseconds: milliseconds, itemCount: statuses.count, outcome: .values)
                lastSuccess = Date(); publish(statuses)
            case .permissionDenied:
                lastSample = NativeDockStatusSample(sequence: sequence, processIdentifier: pid, durationMilliseconds: milliseconds, itemCount: 0, outcome: .permissionDenied)
                lastSuccess = nil; publish([:])
            case .temporarilyUnavailable:
                lastSample = NativeDockStatusSample(sequence: sequence, processIdentifier: pid, durationMilliseconds: milliseconds, itemCount: 0, outcome: .temporarilyUnavailable)
                // Dock 短时更新时保留上一帧，失联超过五秒则清除过期状态。
                if lastSuccess.map({ Date().timeIntervalSince($0) > 5 }) ?? true { publish([:]) }
            }
        }
    }

    private func publish(_ statuses: [String: NativeDockItemStatus]) {
        guard latest != statuses else { return }
        latest = statuses
        onChanged(statuses)
    }
}
