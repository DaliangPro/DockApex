import AppKit
import ApplicationServices
import Darwin

struct DockWorkAreaReport: Codable, Equatable, Sendable {
    var managedWindowCount = 0
    var adjustmentCount = 0
    var restorationCount = 0
    var skippedCount = 0
    var hasAccessibilityPermission = false
}

private struct DockWorkAreaProcess: Equatable, Sendable {
    var pid: pid_t
    var identity: String

    static func capture(_ pid: pid_t) -> Self? {
        guard let identity = token(pid) else { return nil }
        return Self(pid: pid, identity: identity)
    }

    var isValid: Bool { Self.token(pid) == identity }

    private static func token(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }
}

/// MainActor 可以立刻撤销扫描写入资格，不必等后台 AX 同步调用返回才传递新布局。
private final class DockWorkAreaLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
}

private struct DockWorkAreaRequest: Sendable {
    var zones: [DockWorkAreaZone]
    var primaryHeight: CGFloat
    var revision: UInt64
    var front: DockWorkAreaProcess?
    var regularProcesses: [DockWorkAreaProcess]
    var traceURL: URL?
    var pointerBlockedPasses: Int
    var quietBlockedPasses: Int
}

struct DockWorkAreaEvent: Sendable {
    var pid: pid_t
    var text: String
}

private struct DockWorkAreaTraceEvent: Codable, Sendable {
    var pass: Int
    var date: Date
    var kind: String
    var pid: pid_t?
    var windowKey: String?
    var elapsedMS: Int
    var remainingMS: Int
    var frame: [String: Double]?
    var details: String?
}

/// AX 句柄、原窗口尺寸和条件恢复记录只存在这个 actor 中，不记录窗口标题。
private actor DockWorkAreaReader {
    private struct Record {
        var window: AXUIElement
        var process: DockWorkAreaProcess
        var original: CGRect
        var lastApplied: CGRect
        var revision: UInt64
        var number: CGWindowID?
        var appliedAt: TimeInterval
        /// 铺满前窗口停稳的尺寸，再次缩放时还原到这里。
        var previous: CGRect?
        /// 离开 lastApplied 后还没停稳的尺寸（缩放动画途中）。
        var moving: Candidate?
    }
    private struct Candidate {
        var frame: CGRect
        var firstSeen: TimeInterval
        var failures = 0
        var retryAt: TimeInterval = 0
        var refused: Bool { failures >= 3 }
    }
    private struct WindowState {
        var frame: CGRect
        var eligible: Bool
    }
    private var records: [String: Record] = [:]
    private var candidates: [String: Candidate] = [:]
    /// 调整后又被用户或 App 改回去的窗口：不再按“伸进应用栏”接管（铺满或平铺仍照常避让），免得来回较劲。
    private var released = Set<String>()
    /// 屏上不需要让位的窗口最近停稳的尺寸（同一尺寸隔 0.12 秒再看到一次才算），按窗口编号记；
    /// 缩放动画的中间帧和本工具收短后的尺寸不算。
    private var settledFrames: [CGWindowID: CGRect] = [:]
    private var unsettledFrames: [CGWindowID: Candidate] = [:]
    /// 用户再次缩放、却不知道放大前尺寸的窗口（按窗口编号）：停在这个尺寸期间不再让位，下一次缩放交给 App 自己还原。
    private var yielded: [CGWindowID: CGRect] = [:]
    /// 收短后很快被改回铺满的窗口，每个只记一次日志，免得来回较劲时刷屏。
    private var snappedBack = Set<String>()
    private var events: [DockWorkAreaEvent] = []
    private var counts = DockWorkAreaReport()
    private var lastBackgroundPID: pid_t?
    private let timeout: Float = 0.08
    private var traceURL: URL?
    private var traceEvents: [DockWorkAreaTraceEvent] = []
    private var passNumber = 0
    private var passStarted: TimeInterval = 0
    private var passDeadline: TimeInterval = 0
    private var passBudgetRejections = 0
    private var passScanAttempts = 0

    /// 取走本轮之后发生的少见事件（再次缩放还原、留在铺满、收短后被改回），由服务写进活动日志。
    func takeEvents() -> [DockWorkAreaEvent] {
        defer { events.removeAll() }
        return events
    }

    /// 最早一次待重试的写入时刻；写入没生效时只有窗口事件或 4 秒兜底才会再看，由服务按这个时刻主动再查一轮。
    func nextRetry() -> TimeInterval? {
        candidates.values.filter { $0.failures > 0 && !$0.refused }.map(\.retryAt).min()
    }

    private func note(_ pid: pid_t, _ text: String) {
        events.append(DockWorkAreaEvent(pid: pid, text: text))
    }

    func synchronize(_ request: DockWorkAreaRequest, lease: DockWorkAreaLease) -> DockWorkAreaReport {
        traceURL = request.traceURL
        if traceURL == nil { traceEvents.removeAll() }
        passNumber &+= 1
        passStarted = ProcessInfo.processInfo.systemUptime
        passDeadline = passStarted + 1.0
        passBudgetRejections = 0; passScanAttempts = 0
        defer {
            trace("pass-end", details: "scanAttempts=\(passScanAttempts) budgetRejections=\(passBudgetRejections) managed=\(records.count)")
            saveTrace()
        }
        counts.hasAccessibilityPermission = AXIsProcessTrusted()
        guard counts.hasAccessibilityPermission, lease.isValid, !Task.isCancelled else {
            trace("pass-blocked", details: "trusted=\(counts.hasAccessibilityPermission) lease=\(lease.isValid) cancelled=\(Task.isCancelled)")
            return report()
        }
        let started = passStarted
        let deadline = passDeadline
        let visible = visibleWindowFrames(primaryHeight: request.primaryHeight, zones: request.zones)
        let background = backgroundProcess(for: request, visibleFrames: visible)
        trace("pass-start", pid: request.front?.pid,
              details: "foregroundPID=\(request.front?.pid ?? 0) backgroundPID=\(background?.pid ?? 0) pointerBlocked=\(request.pointerBlockedPasses) quietBlocked=\(request.quietBlockedPasses) zones=\(request.zones.map { $0.displayUUID + ":" + $0.usableFrame.debugDescription }.joined(separator: ";"))")
        let monitored = Set([request.front?.pid, background?.pid].compactMap { $0 })
        let keys = records.keys.sorted { left, right in
            let a = records[left]?.process.pid == request.front?.pid
            let b = records[right]?.process.pid == request.front?.pid
            return a == b ? left < right : a
        }
        for key in keys {
            guard permitted(lease, deadline: deadline) else { return report() }
            guard var record = records[key] else { continue }
            guard record.process.isValid else { records[key] = nil; candidates[key] = nil; continue }
            guard record.revision != request.revision || monitored.contains(record.process.pid) else { continue }
            guard let current = state(of: record.window, primaryHeight: request.primaryHeight) else { continue }
            // 原生全屏、最小化和模态状态不会被本工具退出或切屏时强行调整。
            guard current.eligible else { continue }
            let time = ProcessInfo.processInfo.systemUptime
            guard DockWorkAreaGeometry.restoreFrame(original: record.original, lastApplied: record.lastApplied, current: current.frame) != nil else {
                // 再次缩放（双击标题栏等）：App 以为底部没有 Dock，收短后的窗口不算放大状态，又铺满一次。
                // 按原生习惯还原到铺满前的尺寸，否则每次双击都是铺满再被收短，永远缩不回去。
                // 收短后 0.5 秒内就回到铺满，是 App 或系统把窗口改回去（例如浏览器、系统平铺），不是用户再次缩放，照旧重新让位。
                let reverted = DockWorkAreaGeometry.approximatelyEqual(current.frame, record.original)
                if reverted, time - record.appliedAt < 0.5 {
                    if snappedBack.insert(key).inserted { note(record.process.pid, "收短后又被改回铺满，重新让位") }
                } else if reverted {
                    let number = record.number
                    // 期间在别的尺寸停稳过（后台窗口改尺寸时可能没轮到检查）：这是从新尺寸放大，按新窗口重新让位。
                    let resized = number.flatMap { settledFrames[$0] }.map { settled in
                        !DockWorkAreaGeometry.approximatelyEqual(settled, record.lastApplied)
                            && !(record.previous.map { DockWorkAreaGeometry.approximatelyEqual(settled, $0) } ?? false)
                    } ?? false
                    if !resized {
                        if let previous = record.previous, !DockWorkAreaGeometry.approximatelyEqual(previous, record.lastApplied) {
                            guard let applied = write(previous, to: record.window, expected: current.frame, process: record.process,
                                                      primaryHeight: request.primaryHeight, lease: lease, deadline: deadline) else { continue }
                            counts.restorationCount += 1
                            if let number { settledFrames[number] = applied }
                            note(record.process.pid, "再次缩放，还原到放大前的尺寸")
                            trace("window-unzoomed", pid: record.process.pid, windowKey: key, frame: applied)
                        } else {
                            if let number { yielded[number] = current.frame }
                            note(record.process.pid, "再次缩放，不知道放大前的尺寸，留在铺满状态")
                            trace("window-yielded", pid: record.process.pid, windowKey: key, frame: current.frame)
                        }
                        records[key] = nil; candidates[key] = nil
                        continue
                    }
                } else if let moving = record.moving, DockWorkAreaGeometry.approximatelyEqual(moving.frame, current.frame) {
                    // 缩放动画途中先不下结论，停稳后才知道是又被放大还是用户改了尺寸。
                    if time - moving.firstSeen < 0.12 { continue }
                } else {
                    records[key]?.moving = Candidate(frame: current.frame, firstSeen: time)
                    continue
                }
                // 用户改过后立即放弃旧尺寸的恢复资格；若其再次明确填充或平铺，
                // 后面的新候选流程以新尺寸重新连续观察两轮，不永久封禁这个窗口。
                records[key] = nil; candidates[key] = nil; counts.skippedCount += 1
                released.insert(key)
                continue
            }
            record.moving = nil
            let desired = DockWorkAreaGeometry.adjustedFrame(record.original, zones: request.zones, allowIntruding: true)?.frame ?? record.original
            if !DockWorkAreaGeometry.approximatelyEqual(current.frame, desired) {
                guard let applied = write(desired, to: record.window, expected: current.frame, process: record.process,
                                          primaryHeight: request.primaryHeight, lease: lease, deadline: deadline) else { continue }
                if DockWorkAreaGeometry.approximatelyEqual(applied, record.original) {
                    records[key] = nil; counts.restorationCount += 1
                    continue
                }
                record.lastApplied = applied
                record.appliedAt = ProcessInfo.processInfo.systemUptime
                counts.adjustmentCount += 1
            }
            record.revision = request.revision
            records[key] = record
        }
        guard !request.zones.isEmpty, permitted(lease, deadline: deadline) else { return report() }
        if let process = request.front, process.isValid {
            scan(process: process, request: request, visibleFrames: nil,
                 lease: lease, deadline: min(deadline, started + 0.30))
        }
        if let process = background, permitted(lease, deadline: deadline) {
            lastBackgroundPID = process.pid
            scan(process: process, request: request, visibleFrames: visible[process.pid] ?? [],
                 lease: lease, deadline: deadline)
        }
        return report()
    }

    private func scan(process: DockWorkAreaProcess, request: DockWorkAreaRequest, visibleFrames: [CGRect]?,
                      lease: DockWorkAreaLease, deadline: TimeInterval) {
        guard process.isValid, permitted(lease, deadline: deadline) else { return }
        passScanAttempts += 1
        trace("scan-start", pid: process.pid, details: visibleFrames == nil ? "foreground" : "background")
        let application = AXUIElementCreateApplication(process.pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { trace("scan-unavailable", pid: process.pid); return }
        let prefix = "\(process.pid):\(process.identity):"
        var visibleKeys = Set<String>()
        for window in windows.prefix(32) {
            guard permitted(lease, deadline: deadline), process.isValid else { break }
            let key = prefix + String(CFHash(window))
            visibleKeys.insert(key)
            guard records[key] == nil else { continue }
            guard let current = state(of: window, primaryHeight: request.primaryHeight) else {
                candidates[key] = nil
                trace("window-unreadable", pid: process.pid, windowKey: key)
                continue
            }
            guard current.eligible else {
                candidates[key] = nil
                trace("window-ineligible", pid: process.pid, windowKey: key, frame: current.frame)
                continue
            }
            if !yielded.isEmpty, let number = DockFloatingAvoidance.windowNumber(window),
               let frame = yielded[number], DockWorkAreaGeometry.approximatelyEqual(frame, current.frame) {
                candidates[key] = nil
                continue
            }
            guard visibleFrames.map({ frames in frames.contains { DockWorkAreaGeometry.approximatelyEqual($0, current.frame, tolerance: 3) } }) ?? true,
                  let adjustment = DockWorkAreaGeometry.adjustedFrame(current.frame, zones: request.zones,
                                                                      allowIntruding: !released.contains(key)) else {
                // 普通小窗、拖动后的新位置和非标准状态不保留旧的稳定计时。
                candidates[key] = nil
                trace("window-geometry-skip", pid: process.pid, windowKey: key, frame: current.frame)
                continue
            }
            let time = ProcessInfo.processInfo.systemUptime
            if let candidate = candidates[key], DockWorkAreaGeometry.approximatelyEqual(candidate.frame, current.frame) {
                guard !candidate.refused, time - candidate.firstSeen >= 0.12, time >= candidate.retryAt else { continue }
                let number = DockFloatingAvoidance.windowNumber(window)
                let previous = number.flatMap { settledFrames[$0] }
                guard let applied = write(adjustment.frame, to: window, expected: current.frame, process: process,
                                          primaryHeight: request.primaryHeight, lease: lease, deadline: deadline) else { continue }
                guard !DockWorkAreaGeometry.approximatelyEqual(applied, current.frame) else {
                    // 写入执行了但没生效：App 正忙于自己的动画或一时没处理都会这样，隔 1 秒再试；连续三次不生效才放手，
                    // 同一位置不再反复写，也不再占后台优先；窗口再变化时重新观察。
                    candidates[key]?.failures += 1
                    candidates[key]?.retryAt = time + 1
                    if candidates[key]?.refused == true { note(process.pid, "收短连续三次没生效，窗口再变化时才重试") }
                    continue
                }
                records[key] = Record(window: window, process: process, original: current.frame, lastApplied: applied,
                                      revision: request.revision, number: number, appliedAt: ProcessInfo.processInfo.systemUptime,
                                      previous: previous)
                candidates[key] = nil
                counts.adjustmentCount += 1
                trace("window-adjusted", pid: process.pid, windowKey: key, frame: applied,
                      details: "window=\(number.map(String.init) ?? "nil") previous=\(previous?.debugDescription ?? "nil")")
            } else {
                candidates[key] = Candidate(frame: current.frame, firstSeen: time)
                trace("window-candidate", pid: process.pid, windowKey: key, frame: current.frame)
            }
        }
        // 只清理本次完整列出的应用，不能把未轮询的其他应用恢复资格误删。
        if permitted(lease, deadline: deadline), windows.count <= 32 {
            for key in Array(records.keys) where key.hasPrefix(prefix) && !visibleKeys.contains(key) { records[key] = nil }
            candidates = candidates.filter { !$0.key.hasPrefix(prefix) || visibleKeys.contains($0.key) }
            released = released.filter { !$0.hasPrefix(prefix) || visibleKeys.contains($0) }
            snappedBack = snappedBack.filter { !$0.hasPrefix(prefix) || visibleKeys.contains($0) }
        }
    }

    private func backgroundProcess(for request: DockWorkAreaRequest, visibleFrames: [pid_t: [CGRect]]) -> DockWorkAreaProcess? {
        guard !request.zones.isEmpty else { return nil }
        let managed = Set(records.values.map { $0.process.pid })
        let pending = Set(candidates.filter { !$0.value.refused }.keys.compactMap { pid_t($0.prefix { $0 != ":" }) })
        var intruding = Set<pid_t>()
        let eligible = request.regularProcesses.filter { process in
            guard process.pid != request.front?.pid, process.isValid, let frames = visibleFrames[process.pid] else { return false }
            if frames.contains(where: { DockWorkAreaGeometry.adjustedFrame($0, zones: request.zones, allowIntruding: true) != nil }) {
                intruding.insert(process.pid)
            }
            return managed.contains(process.pid) || intruding.contains(process.pid)
        }.sorted { $0.pid < $1.pid }
        // 只因已有接管记录入选的程序窗口已让好位置；若与它们平均轮换，待确认的第二眼会被挤到 4 秒兜底之后，
        // 非前台程序自己放大的窗口迟迟收不回。先轮已看过一次待确认的，再轮窗口正伸进应用栏的。
        guard let pool = [eligible.filter { pending.contains($0.pid) }, eligible.filter { intruding.contains($0.pid) }, eligible]
            .first(where: { !$0.isEmpty }) else { return nil }
        return lastBackgroundPID.flatMap { previous in pool.first { $0.pid > previous } } ?? pool.first
    }

    /// 顺带记下不需要让位的窗口停稳的尺寸：每轮都会读整张列表，放大前不管是不是前台、有没有被扫描都能记到。
    private func visibleWindowFrames(primaryHeight: CGFloat, zones: [DockWorkAreaZone]) -> [pid_t: [CGRect]] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: [CGRect]] = [:]
        let time = ProcessInfo.processInfo.systemUptime
        var seen = Set<CGWindowID>()
        let applied = Dictionary(records.values.compactMap { record in record.number.map { ($0, record.lastApplied) } }) { first, _ in first }
        for item in windows {
            guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary), bounds.width >= 280, bounds.height >= 160 else { continue }
            // 不读取窗口名；后台接管必须能与本轮公开的 onscreen 几何匹配。
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            result[pid, default: []].append(frame)
            guard let number = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let held = yielded[number], !DockWorkAreaGeometry.approximatelyEqual(held, frame) { yielded[number] = nil }
            guard DockWorkAreaGeometry.adjustedFrame(frame, zones: zones, allowIntruding: true) == nil,
                  !(applied[number].map { DockWorkAreaGeometry.approximatelyEqual($0, frame) } ?? false) else { continue }
            seen.insert(number)
            if let last = unsettledFrames[number], DockWorkAreaGeometry.approximatelyEqual(last.frame, frame) {
                if time - last.firstSeen >= 0.12 { settledFrames[number] = frame }
            } else {
                unsettledFrames[number] = Candidate(frame: frame, firstSeen: time)
            }
        }
        // 铺满或伸进应用栏的窗口保留放大前的尺寸；关掉或不在屏上的窗口不再保留。
        let onScreen = Set(windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        settledFrames = settledFrames.filter { onScreen.contains($0.key) }
        unsettledFrames = unsettledFrames.filter { seen.contains($0.key) }
        yielded = yielded.filter { onScreen.contains($0.key) }
        return result
    }

    func restoreAll(primaryHeight: CGFloat, pointerIsReleased: Bool) -> DockWorkAreaReport {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        let lease = DockWorkAreaLease()
        if pointerIsReleased, AXIsProcessTrusted() {
            for record in records.values {
                guard permitted(lease, deadline: deadline) else { break }
                guard record.process.isValid,
                      let current = state(of: record.window, primaryHeight: primaryHeight), current.eligible,
                      DockWorkAreaGeometry.restoreFrame(original: record.original, lastApplied: record.lastApplied, current: current.frame) != nil,
                      let applied = write(record.original, to: record.window, expected: current.frame, process: record.process,
                                          primaryHeight: primaryHeight, lease: lease, deadline: deadline),
                      DockWorkAreaGeometry.approximatelyEqual(applied, record.original) else { counts.skippedCount += 1; continue }
                counts.restorationCount += 1
            }
        }
        records.removeAll(); candidates.removeAll(); lastBackgroundPID = nil
        settledFrames.removeAll(); unsettledFrames.removeAll(); yielded.removeAll()
        return report()
    }

    private func report() -> DockWorkAreaReport {
        var result = counts
        result.managedWindowCount = records.count
        return result
    }

    private func permitted(_ lease: DockWorkAreaLease, deadline: TimeInterval) -> Bool {
        let inBudget = ProcessInfo.processInfo.systemUptime < deadline
        if !inBudget {
            passBudgetRejections += 1
            trace("budget-rejected", details: "subdeadlineMS=\(Int((deadline - passStarted) * 1000))")
        }
        return lease.isValid && !Task.isCancelled && inBudget
    }

    private func state(of window: AXUIElement, primaryHeight: CGFloat) -> WindowState? {
        AXUIElementSetMessagingTimeout(window, timeout)
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute, kAXSubroleAttribute,
                     kAXMinimizedAttribute, "AXFullScreen", kAXModalAttribute] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, names, [], &raw) == .success,
              let values = raw as? [Any], values.count == 7,
              let position = point(values[0]), let size = size(values[1]), size.width > 1, size.height > 1 else { return nil }
        let frame = CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
        let roleFits = (values[2] as? String) == kAXWindowRole && (values[3] as? String) == kAXStandardWindowSubrole
        let active = (values[4] as? Bool) != true && (values[5] as? Bool) != true && (values[6] as? Bool) != true
        // 先按几何和角色筛选；对普通小窗查两次 Settable 会耗尽后台扫描预算。
        return WindowState(frame: frame, eligible: roleFits && active)
    }

    private func write(_ target: CGRect, to window: AXUIElement, expected: CGRect, process: DockWorkAreaProcess,
                       primaryHeight: CGFloat, lease: DockWorkAreaLease, deadline: TimeInterval) -> CGRect? {
        // 连续读取后用户仍可能开始拖动，因此每次实际写入前再次检查公开按键状态。
        guard permitted(lease, deadline: deadline), process.isValid,
              pointerIsReleased,
              let before = state(of: window, primaryHeight: primaryHeight), before.eligible,
              DockWorkAreaGeometry.approximatelyEqual(before.frame, expected) else { return nil }
        var canPosition = DarwinBoolean(false), canResize = DarwinBoolean(false)
        guard permitted(lease, deadline: deadline),
              AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &canPosition) == .success, canPosition.boolValue,
              permitted(lease, deadline: deadline),
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &canResize) == .success, canResize.boolValue else {
            trace("write-not-settable", pid: process.pid, frame: before.frame)
            return nil
        }
        var targetSize = target.size
        var targetPosition = CGPoint(x: target.minX, y: primaryHeight - target.maxY)
        guard let sizeValue = AXValueCreate(.cgSize, &targetSize), let positionValue = AXValueCreate(.cgPoint, &targetPosition) else { return nil }
        // 先收缩再移动，避免底部或侧边越界时应用把窗口自动钳回旧屏幕区域。
        let shrinking = target.width <= before.frame.width && target.height <= before.frame.height
        let attributes: [(CFString, AXValue)] = shrinking
            ? [(kAXSizeAttribute as CFString, sizeValue), (kAXPositionAttribute as CFString, positionValue)]
            : [(kAXPositionAttribute as CFString, positionValue), (kAXSizeAttribute as CFString, sizeValue)]
        trace("write-request", pid: process.pid, frame: target, details: "before=\(before.frame.debugDescription)")
        var lastKnown = before.frame
        for (name, value) in attributes {
            guard permitted(lease, deadline: deadline), process.isValid, pointerIsReleased else { break }
            guard AXUIElementSetAttributeValue(window, name, value) == .success else { break }
            if name == kAXSizeAttribute as CFString {
                // AXSize 保持 Quartz 顶边，转换到 AppKit 时底边随高度改变。
                lastKnown.origin.y = lastKnown.maxY - target.height
                lastKnown.size = target.size
            } else {
                lastKnown.origin.x = target.minX
                lastKnown.origin.y = primaryHeight - targetPosition.y - lastKnown.height
            }
        }
        // 约束尺寸或布局取消可能只完成一部分；必须记录真实结果才有条件恢复的依据。
        let after = state(of: window, primaryHeight: primaryHeight)?.frame
        trace("write-result", pid: process.pid, frame: after ?? lastKnown,
              details: "target=\(target.debugDescription) lease=\(lease.isValid) pointerReleased=\(pointerIsReleased)")
        // 用户在两次 AX 写入之间开始拖动时，不能把其新位置登记成本工具拥有的尺寸。
        return lease.isValid && pointerIsReleased ? (after ?? lastKnown) : lastKnown
    }

    private func trace(_ kind: String, pid: pid_t? = nil, windowKey: String? = nil,
                       frame: CGRect? = nil, details: String? = nil) {
        guard traceURL != nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let encodedFrame = frame.map { ["x": Double($0.minX), "y": Double($0.minY), "width": Double($0.width), "height": Double($0.height)] }
        traceEvents.append(DockWorkAreaTraceEvent(pass: passNumber, date: Date(), kind: kind, pid: pid,
            windowKey: windowKey, elapsedMS: Int((time - passStarted) * 1000), remainingMS: max(0, Int((passDeadline - time) * 1000)),
            frame: encodedFrame, details: details))
        if traceEvents.count > 100 { traceEvents.removeFirst(traceEvents.count - 100) }
    }

    private func saveTrace() {
        guard let traceURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(traceEvents) else { return }
        try? data.write(to: traceURL, options: .atomic)
    }

    private var pointerIsReleased: Bool {
        [CGMouseButton.left, .right, .center].allSatisfy { !CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }

    private func point(_ raw: Any) -> CGPoint? {
        let object = raw as AnyObject
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = object as! AXValue
        var result = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &result) else { return nil }
        return result
    }

    private func size(_ raw: Any) -> CGSize? {
        let object = raw as AnyObject
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = object as! AXValue
        var result = CGSize.zero
        guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &result) else { return nil }
        return result
    }
}

/// 兼容工作区：通过公开 AX 调整符合条件的填充/平铺窗口；系统真正的 visibleFrame 保持不变。
@MainActor
final class DockWorkAreaService {
    var onChange: ((DockWorkAreaReport) -> Void)?
    var onEvent: ((DockWorkAreaEvent) -> Void)?
    private(set) var lastReport = DockWorkAreaReport()
    private let reader = DockWorkAreaReader()
    private var areas: [DockReservedArea] = []
    private var revision: UInt64 = 0
    private var enabled = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var settleTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var regularProcesses: [pid_t: DockWorkAreaProcess] = [:]
    private var frontProcess: DockWorkAreaProcess?
    private var workTask: Task<Void, Never>?
    private var lease: DockWorkAreaLease?
    private var needsPass = false
    private var lastMouseDown: TimeInterval = 0
    private var pointerBlockedPasses = 0
    private var quietBlockedPasses = 0
    private lazy var traceDirectory: URL = {
        let root = Bundle.main.object(forInfoDictionaryKey: "WorkspaceRoot") as? String ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: root).appendingPathComponent("Data/Diagnostics", isDirectory: true)
    }()

    func start() {
        guard !enabled else { return }
        enabled = true
        for app in NSWorkspace.shared.runningApplications { updateProcess(app) }
        if let app = NSWorkspace.shared.frontmostApplication { frontProcess = regularProcesses[app.processIdentifier] }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            let invalidatesGeometry = name != NSWorkspace.didActivateApplicationNotification
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let terminated = name == NSWorkspace.didTerminateApplicationNotification
                let activated = name == NSWorkspace.didActivateApplicationNotification
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let pid {
                        if terminated { self.regularProcesses[pid] = nil }
                        else if let app = NSRunningApplication(processIdentifier: pid) { self.updateProcess(app) }
                        if activated || self.frontProcess?.pid == pid { self.frontProcess = self.regularProcesses[pid] }
                        if terminated, self.frontProcess?.pid == pid { self.frontProcess = nil }
                    }
                    // 激活其他应用不会改变保留区；反复撤销正在进行的后台扫描会造成饥饿。
                    if invalidatesGeometry { self.invalidatePass() }
                    self.requestWindowUpdate()
                }
            })
        }
        // AX 窗口事件负责即时处理；低频兜底只服务不发送窗口通知的应用。
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.requestPass() } }
        timer.tolerance = 0.4; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        requestWindowUpdate()
    }

    func update(_ areas: [DockReservedArea]) {
        guard self.areas != areas else { return }
        self.areas = areas; revision &+= 1
        invalidatePass(); requestWindowUpdate()
    }

    /// 连续观察两次才认定填充/平铺；跟随窗口事件，不在主线程反复枚举 LaunchServices。
    func requestWindowUpdate() {
        guard enabled else { return }
        requestPass()
        settleTask?.cancel()
        // 事件后 150 与 300 毫秒各看一次：放大动画结束后约 150 毫秒即可确认稳定并让位。
        settleTask = Task { @MainActor [weak self] in
            for delay in [150, 150] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, self.enabled, !Task.isCancelled else { return }
                self.requestPass()
            }
            self?.settleTask = nil
        }
    }

    private func updateProcess(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, !app.isTerminated, !app.isHidden,
              app.activationPolicy == .regular else { regularProcesses[pid] = nil; return }
        regularProcesses[pid] = DockWorkAreaProcess.capture(pid)
    }

    /// 恢复在后台有界执行。退出方应 await 返回，或在 completion 后回复 terminateLater。
    func stopAndRestore() async {
        enabled = false
        timer?.invalidate(); timer = nil
        settleTask?.cancel(); settleTask = nil
        retryTask?.cancel(); retryTask = nil
        regularProcesses.removeAll(); frontProcess = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        invalidatePass(); needsPass = false
        // 菜单选择退出时保留短暂的鼠标释放机会，仍按住拖动则放弃调整，不争抢用户手势。
        for _ in 0..<5 where NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(50)) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let result = await reader.restoreAll(primaryHeight: primaryHeight, pointerIsReleased: NSEvent.pressedMouseButtons == 0)
        publish(result)
    }

    func stopAndRestore(completion: @escaping () -> Void) {
        Task { [weak self] in await self?.stopAndRestore(); completion() }
    }

    /// 应用栏占位区（左下原点）；窗口避让与悬浮条避让共用。
    static func zones(for areas: [DockReservedArea]) -> [DockWorkAreaZone] {
        let screens = NSScreen.screens
        return areas.map { area in
            let screen = screens.first { DockDisplayDescriptor.uuid(for: $0) == area.displayUUID }
            return DockWorkAreaZone(displayUUID: area.displayUUID, screenFrame: area.screenFrame,
                                    usableFrame: DockWorkAreaGeometry.normalizedUsableFrame(screenFrame: area.screenFrame,
                                        reportedVisibleFrame: screen?.visibleFrame ?? area.screenFrame),
                                    reservedFrame: area.reservedFrame, position: area.position,
                                    reportedVisibleFrame: screen?.visibleFrame)
        }
    }

    private func invalidatePass() { lease?.cancel(); workTask?.cancel(); if workTask != nil { needsPass = true } }

    private func requestPass() {
        guard enabled, !areas.isEmpty || lastReport.managedWindowCount > 0 else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if NSEvent.pressedMouseButtons != 0 { lastMouseDown = time; pointerBlockedPasses += 1; return }
        guard time - lastMouseDown >= 0.2 else { quietBlockedPasses += 1; return }
        guard workTask == nil else { needsPass = true; return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let zones = Self.zones(for: areas)
        let front = frontProcess
        let regular = Array(regularProcesses.values)
        let traceEnabled = FileManager.default.fileExists(atPath: traceDirectory.appendingPathComponent("0.4-workarea-trace.enabled").path)
        let request = DockWorkAreaRequest(zones: zones, primaryHeight: primaryHeight, revision: revision, front: front, regularProcesses: regular,
            traceURL: traceEnabled ? traceDirectory.appendingPathComponent("0.4-workarea-trace.json") : nil,
            pointerBlockedPasses: pointerBlockedPasses, quietBlockedPasses: quietBlockedPasses)
        let lease = DockWorkAreaLease(); self.lease = lease
        workTask = Task { [weak self, reader] in
            let result = await reader.synchronize(request, lease: lease)
            let events = await reader.takeEvents()
            let retry = await reader.nextRetry()
            guard let self else { return }
            for event in events { onEvent?(event) }
            if let retry { scheduleRetry(at: retry) }
            workTask = nil; self.lease = nil
            if lease.isValid, enabled { publish(result) }
            if needsPass { needsPass = false; requestPass() }
        }
    }

    private func scheduleRetry(at time: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, time - ProcessInfo.processInfo.systemUptime) + 0.05)) } catch { return }
            self?.retryTask = nil
            self?.requestPass()
        }
    }

    private func publish(_ result: DockWorkAreaReport) {
        guard result != lastReport else { return }
        lastReport = result; onChange?(result)
    }
}
