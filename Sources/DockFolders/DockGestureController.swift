import AppKit
import ApplicationServices

struct DockHoverIdentity: Sendable {
    let item: DockAppItem
    let dockPID: pid_t
    let point: CGPoint
    let readAt: TimeInterval
}

/// 拖叠的命中与时间规则不依赖输入拦截，可离线核验。
enum DockGestureRules {
    static let dwellDuration: TimeInterval = 0.55
    static let dragThreshold: CGFloat = 7
    static let maximumSnapshotAge: TimeInterval = 0.8

    static func item(at point: CGPoint, in items: [DockAppItem], centralOnly: Bool,
                     excluding excludedURL: URL? = nil) -> DockAppItem? {
        items.filter { item in
            guard item.appURL != excludedURL else { return false }
            let frame = centralOnly ? item.frame.insetBy(dx: item.frame.width * 0.20, dy: item.frame.height * 0.20) : item.frame
            return frame.contains(point)
        }.min { lhs, rhs in
            hypot(lhs.frame.midX - point.x, lhs.frame.midY - point.y)
                < hypot(rhs.frame.midX - point.x, rhs.frame.midY - point.y)
        }
    }

    static func trustedHover(_ hover: DockHoverIdentity?, candidate: DockAppItem?, dockPID: pid_t,
                             point: CGPoint, now: TimeInterval) -> DockAppItem? {
        guard let hover, hover.dockPID == dockPID, now >= hover.readAt, now - hover.readAt <= 0.25,
              hover.item.frame.contains(point), hypot(hover.point.x - point.x, hover.point.y - point.y) <= 10,
              candidate == nil || candidate?.appURL.standardizedFileURL == hover.item.appURL.standardizedFileURL else { return nil }
        return hover.item
    }

    static func dragboardSource(candidate: DockAppItem?, urls: [URL], baseline: Int?, change: Int,
                                dockConfirmed: Bool, dockPID: pid_t, currentDockPID: pid_t,
                                hasDragged: Bool, knownItems: [DockAppItem]) -> DockAppItem? {
        guard dockConfirmed, hasDragged, dockPID == currentDockPID, let baseline, baseline != change,
              urls.count == 1, let url = urls.first, url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }
        let identity = url.standardizedFileURL
        if let candidate { return candidate.appURL.standardizedFileURL == identity ? candidate : nil }
        return knownItems.first { $0.appURL.standardizedFileURL == identity }
    }

    static func sourceMatches(candidate: DockAppItem?, actual: DockAppItem?, hasDragged: Bool) -> Bool {
        guard let actual else { return false }
        if let candidate { return candidate.appURL.standardizedFileURL == actual.appURL.standardizedFileURL }
        // 缺少缓存时只接受仍未开始拖动的按下点补读，不能把让位后的邻居当作源。
        return !hasDragged
    }

    static func isReady(hasDragged: Bool, enteredAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard hasDragged, let enteredAt else { return false }
        return now - enteredAt >= dwellDuration
    }
}

/// 只观察原生鼠标流：点击、长按、排序和拖出 Dock 始终直接交给系统。
/// 绝不吞事件、暂存回放、发送 Esc，因而不会把 Dock 的渲染卡在输入回调中。
@MainActor
final class DockGestureController {
    private struct TapArguments: @unchecked Sendable {
        let event: CGEvent
        let context: UnsafeMutableRawPointer
    }
    private struct Gesture: Sendable {
        let id = UUID()
        var source: DockAppItem?
        let start: CGPoint
        let initialItems: [DockAppItem]
        let dockPID: pid_t
        var pointTarget: DockAppItem?
        var pointTargetTime: TimeInterval = 0
        var sourceVerified = false
        var dockOriginConfirmed = false
        var dragBoardChangeAtDown: Int?
        var lastReadBoardChange: Int?
        var hasDragged = false
        var target: DockAppItem?
        var targetEnteredAt: TimeInterval?
        var location: CGPoint
    }

    private let onGroup: (URL, URL, CGPoint) -> Void
    private let onHover: (String?, CGPoint) -> Void
    private let onStatus: (String) -> Void
    private let diagnostics: DockGestureDiagnostics
    var onSnapshot: ((DockAccessibilitySnapshot) -> Void)?
    private(set) var isEnabled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var refreshTimer: Timer?
    private var snapshot: DockAccessibilitySnapshot?
    private var snapshotTime: TimeInterval = 0
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var inputSequence = 0
    private var gesture: Gesture?
    private var lastFeedback: String?
    private var lastFeedbackPoint = CGPoint.zero
    private var lastRefreshStart: TimeInterval = 0
    private var pointReadTask: Task<Void, Never>?
    private var lastPointReadAt: TimeInterval = 0
    private var hoverIdentity: DockHoverIdentity?
    private var hoverReadTask: Task<Void, Never>?
    private var lastPointerLocation: CGPoint?
    private var lastHoverReadAt: TimeInterval = 0

    init(onGroup: @escaping (URL, URL, CGPoint) -> Void,
         onHover: @escaping (String?, CGPoint) -> Void,
         onStatus: @escaping (String) -> Void,
         diagnosticsDirectory: URL? = nil) {
        diagnostics = DockGestureDiagnostics(directory: diagnosticsDirectory)
        self.onGroup = onGroup
        self.onHover = onHover
        self.onStatus = onStatus
    }

    @discardableResult
    func start() -> Bool {
        if isEnabled { return true }
        guard DockAccessibility.hasAccessibilityPermission else {
            diagnostics.record(.startDeniedAX)
            onStatus("拖叠尚未启用：请允许辅助功能；普通 Dock 操作始终由系统处理。")
            return false
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                         options: .listenOnly, eventsOfInterest: mask,
                                         callback: Self.eventCallback, userInfo: context),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            diagnostics.record(.startDeniedTap)
            onStatus("拖叠尚未启用：系统没有开放输入观察。原生点击、排序和右键均可正常使用。")
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isEnabled = true
        generation += 1
        diagnostics.record(.started, numbers: ["listenOnly": 1, "tapEnabled": CGEvent.tapIsEnabled(tap: tap) ? 1 : 0])
        refreshSnapshot(force: true)
        // 空闲每 350 ms 刷新身份；拖动时才增加刷新频率，不做逐帧 AX 调用。
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.diagnostics.poll()
                self.refreshSnapshot()
                self.refreshHoverIdentity()
                self.updateFeedback()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        onStatus("已使用原生 Dock；拖到另一应用中央，停留片刻后松手建组。")
        return true
    }

    func stop() {
        diagnostics.record(.stopped)
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        pointReadTask?.cancel()
        pointReadTask = nil
        hoverReadTask?.cancel()
        hoverReadTask = nil
        hoverIdentity = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        gesture = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        snapshot = nil
        isEnabled = false
        emitFeedback(nil, at: .zero)
    }

    private nonisolated static let eventCallback: CGEventTapCallBack = { _, type, event, context in
        if let context {
            let arguments = TapArguments(event: event, context: context)
            MainActor.assumeIsolated {
                let controller = Unmanaged<DockGestureController>.fromOpaque(arguments.context).takeUnretainedValue()
                controller.observe(type, arguments.event)
            }
        }
        // 即便误判、权限失效或读取失败，也绝不改变原始输入。
        return Unmanaged.passUnretained(event)
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            diagnostics.record(.tapDisabled, numbers: ["type": Double(type.rawValue)])
            gesture = nil
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            emitFeedback(nil, at: .zero)
            return
        }
        guard isEnabled else { return }
        diagnostics.count(type)
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                if gesture != nil { diagnostics.record(.cancelledEscape) }
                inputSequence += 1
                gesture = nil
                emitFeedback(nil, at: .zero)
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .mouseMoved:
            lastPointerLocation = event.location
            if gesture != nil, CGEventSource.buttonState(.combinedSessionState, button: .left) {
                diagnostics.increment(.movedWithButton)
                observe(.leftMouseDragged, event)
            } else { refreshHoverIdentity() }
        case .leftMouseDown:
            inputSequence += 1
            gesture = nil
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty else {
                diagnostics.increment(.downModifiers); return
            }
            guard let pid = DockAccessibility.dockProcessID else {
                diagnostics.record(.downNoDock); return
            }
            let recent = snapshot.flatMap { $0.processID == pid && now - snapshotTime < DockGestureRules.maximumSnapshotAge ? $0 : nil }
            let candidate = recent.flatMap { DockGestureRules.item(at: event.location, in: $0.items, centralOnly: false) }
            let trusted = DockGestureRules.trustedHover(hoverIdentity, candidate: candidate, dockPID: pid, point: event.location, now: now)
            let source = trusted ?? candidate
            var started = Gesture(source: source, start: event.location, initialItems: recent?.items ?? [],
                                  dockPID: pid, location: event.location)
            // 这里只取 drag board 的代数作防陈旧基线，不读取任何剪贴板内容。
            if source != nil { started.dragBoardChangeAtDown = NSPasteboard(name: .drag).changeCount }
            if trusted != nil {
                started.sourceVerified = true
                started.dockOriginConfirmed = true
            }
            gesture = started
            if source != nil {
                diagnostics.record(.downCandidate, point: event.location, source: source?.appURL,
                    numbers: ["flags": Double(event.flags.rawValue), "snapshotAgeMS": (now - snapshotTime) * 1000,
                              "snapshotCount": Double(recent?.items.count ?? 0), "complete": recent?.isComplete == true ? 1 : 0])
            } else { diagnostics.increment(.downNoCandidate) }
            if trusted != nil {
                diagnostics.record(.sourcePreverified, point: event.location, source: source?.appURL,
                    numbers: ["hoverAgeMS": (now - (hoverIdentity?.readAt ?? now)) * 1000])
                return
            }
            let point = event.location
            let sourceReadBegan = ProcessInfo.processInfo.systemUptime
            let currentGeneration = generation
            // 精确 URL 核对在后台执行；不同身份只取消，不能换成已经让位的邻居。
            Task { [weak self] in
                let read = await Task.detached(priority: .userInitiated) {
                    let actual = DockAccessibility.applicationItem(at: point, processID: pid)
                    return (actual, actual != nil || DockAccessibility.isDock(at: point, processID: pid))
                }.value
                let actual = read.0
                guard let self, self.generation == currentGeneration else { return }
                guard var active = self.gesture, active.id == started.id else {
                    if started.source != nil { self.diagnostics.record(.sourceSuperseded) }
                    return
                }
                if started.source != nil || actual != nil {
                    self.diagnostics.record(actual == nil ? .sourceMissing : .sourceRead, point: point,
                        source: started.source?.appURL, target: actual?.appURL,
                        numbers: ["elapsedMS": (ProcessInfo.processInfo.systemUptime - sourceReadBegan) * 1000,
                                  "draggedBeforeRead": active.hasDragged ? 1 : 0])
                }
                active.dockOriginConfirmed = read.1
                if DockGestureRules.sourceMatches(candidate: started.source, actual: actual, hasDragged: active.hasDragged) {
                    self.diagnostics.record(.sourceVerified, source: (started.source ?? actual)?.appURL)
                    active.source = started.source ?? actual
                    active.sourceVerified = true
                } else {
                    if started.source != nil || actual != nil { self.diagnostics.record(.sourceRejected) }
                    // 已让位的旧按下点不能再确定 source；保留只读手势，等新 drag board 身份佐证。
                    self.recoverSourceFromDragboard(&active)
                }
                self.gesture = active
            }
        case .leftMouseDragged:
            guard var current = gesture else { diagnostics.increment(.dragWithoutGesture); return }
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty else {
                diagnostics.record(.dragModifiers, numbers: ["flags": Double(event.flags.rawValue)])
                gesture = nil; emitFeedback(nil, at: .zero); return
            }
            current.location = event.location
            if !current.hasDragged, current.source != nil { diagnostics.record(.dragBegan, point: event.location, source: current.source?.appURL) }
            if hypot(current.start.x - event.location.x, current.start.y - event.location.y) >= DockGestureRules.dragThreshold {
                current.hasDragged = true
            }
            recoverSourceFromDragboard(&current)
            updateTarget(&current, now: now)
            gesture = current
        case .leftMouseUp:
            guard var current = gesture else { diagnostics.increment(.upWithoutGesture); return }
            current.location = event.location
            recoverSourceFromDragboard(&current)
            updateTarget(&current, now: now)
            gesture = nil
            emitFeedback(nil, at: event.location)
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let dwellMS = current.targetEnteredAt.map { (now - $0) * 1000 } ?? 0
            if current.source != nil {
                diagnostics.record(.released, point: event.location, source: current.source?.appURL, target: current.target?.appURL,
                    numbers: ["verified": current.sourceVerified ? 1 : 0, "dragged": current.hasDragged ? 1 : 0,
                              "dwellMS": dwellMS, "flags": Double(event.flags.rawValue)])
            }
            guard event.flags.intersection(modifiers).isEmpty else { diagnostics.record(.upModifiers); return }
            guard current.sourceVerified, let source = current.source else { diagnostics.increment(.upUnverifiedSource); return }
            guard let target = current.target else { diagnostics.record(.upNoTarget); return }
            guard DockGestureRules.isReady(hasDragged: current.hasDragged, enteredAt: current.targetEnteredAt, now: now) else {
                diagnostics.record(.upDwellShort, numbers: ["dwellMS": dwellMS]); return
            }
            diagnostics.record(.commitWaiting, source: source.appURL, target: target.appURL)
            let currentGeneration = generation
            let releaseSequence = inputSequence
            let releasePoint = current.location
            let releasePID = current.dockPID
            // 先让原生 Dock 完成此次 drop、写回自身顺序，再按真实新布局提交分组事务。
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self else { return }
                guard self.isEnabled, self.generation == currentGeneration, self.inputSequence == releaseSequence else {
                    self.diagnostics.record(.commitSuperseded); return
                }
                guard DockAccessibility.dockProcessID == releasePID else { self.diagnostics.record(.commitDockChanged); return }
                let stillOnDock = await Task.detached(priority: .userInitiated) {
                    DockAccessibility.isDock(at: releasePoint, processID: releasePID)
                }.value
                guard stillOnDock else { self.diagnostics.record(.releaseNotDock, point: releasePoint); return }
                guard self.isEnabled, self.generation == currentGeneration, self.inputSequence == releaseSequence,
                      DockAccessibility.dockProcessID == releasePID else { self.diagnostics.record(.commitSuperseded); return }
                self.diagnostics.record(.mergeDispatched, point: releasePoint, source: source.appURL, target: target.appURL)
                CFPreferencesAppSynchronize("com.apple.dock" as CFString)
                self.onGroup(source.appURL, target.appURL, releasePoint)
                self.refreshSnapshot(force: true)
            }
        default: break
        }
    }

    private func updateTarget(_ current: inout Gesture, now: TimeInterval) {
        guard current.hasDragged, let source = current.source else { return }
        // 原生排序会把目标让到相邻位置；保留按下时的目标身份和格子，不能让让位动画换掉目标。
        let initial = DockGestureRules.item(at: current.location, in: current.initialItems, centralOnly: true,
                                            excluding: source.appURL)
        let live = snapshot.flatMap {
            DockGestureRules.item(at: current.location, in: $0.items, centralOnly: true, excluding: source.appURL)
        }
        let pointTarget = now - current.pointTargetTime < 0.25 ? current.pointTarget.flatMap {
            DockGestureRules.item(at: current.location, in: [$0], centralOnly: true, excluding: source.appURL)
        } : nil
        let target: DockAppItem?
        if let previous = current.target {
            let initialRect = current.initialItems.first(where: { $0.appURL == previous.appURL })?.frame
            let liveRect = snapshot?.items.first(where: { $0.appURL == previous.appURL })?.frame
            let insideInitial = initialRect?.insetBy(dx: (initialRect?.width ?? 0) * 0.20, dy: (initialRect?.height ?? 0) * 0.20).contains(current.location) == true
            let insideLive = liveRect?.insetBy(dx: (liveRect?.width ?? 0) * 0.20, dy: (liveRect?.height ?? 0) * 0.20).contains(current.location) == true
            let insidePoint = pointTarget?.appURL == previous.appURL
            target = insideInitial || insideLive || insidePoint ? previous : (initial ?? pointTarget ?? live)
        } else {
            target = initial ?? pointTarget ?? live
        }
        if target?.appURL != current.target?.appURL {
            diagnostics.record(.targetChanged, point: current.location, source: source.appURL, target: target?.appURL)
            current.target = target
            current.targetEnteredAt = target == nil ? nil : now
        }
    }

    private func refreshSnapshot(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval: TimeInterval = gesture?.hasDragged == true ? 0.12 : 0.35
        guard isEnabled, refreshTask == nil, force || now - lastRefreshStart >= interval,
              let pid = DockAccessibility.dockProcessID else { return }
        lastRefreshStart = now
        let currentGeneration = generation
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try DockAccessibility.snapshot(processID: pid) } }.value
            guard let self, self.generation == currentGeneration else { return }
            self.refreshTask = nil
            if case .success(let snapshot) = result {
                self.diagnostics.snapshot(count: snapshot.items.count, complete: snapshot.isComplete,
                    milliseconds: (ProcessInfo.processInfo.systemUptime - now) * 1000)
                if let active = self.gesture, active.dockPID != snapshot.processID {
                    self.gesture = nil
                    self.emitFeedback(nil, at: .zero)
                }
                self.snapshot = snapshot
                self.snapshotTime = now
                self.onSnapshot?(snapshot)
            } else { self.diagnostics.increment(.snapshotFailed) }
        }
    }

    private func updateFeedback() {
        guard var current = gesture, current.hasDragged else { return }
        recoverSourceFromDragboard(&current)
        gesture = current
        guard current.sourceVerified else { return }
        let now = ProcessInfo.processInfo.systemUptime
        updateTarget(&current, now: now)
        gesture = current
        refreshPointTargetIfNeeded(current)
        guard let target = current.target else {
            emitFeedback(nil, at: current.location)
            return
        }
        let ready = DockGestureRules.isReady(hasDragged: current.hasDragged, enteredAt: current.targetEnteredAt, now: now)
        if ready { diagnostics.increment(.dwellReady) }
        emitFeedback(ready ? "松开，与“\(target.label)”建组" : "停留片刻，与“\(target.label)”建组", at: current.location)
    }

    private func refreshHoverIdentity() {
        let now = ProcessInfo.processInfo.systemUptime
        guard gesture == nil, hoverReadTask == nil, now - lastHoverReadAt >= 0.16,
              let point = lastPointerLocation, let snapshot,
              now - snapshotTime < DockGestureRules.maximumSnapshotAge,
              DockGestureRules.item(at: point, in: snapshot.items, centralOnly: false) != nil else { return }
        lastHoverReadAt = now
        let token = generation
        let pid = snapshot.processID
        hoverReadTask = Task { [weak self] in
            let item = await Task.detached(priority: .utility) {
                DockAccessibility.applicationItem(at: point, processID: pid)
            }.value
            guard let self, self.generation == token else { return }
            self.hoverReadTask = nil
            guard self.gesture == nil, let item, let currentPoint = self.lastPointerLocation,
                  hypot(currentPoint.x - point.x, currentPoint.y - point.y) <= 5,
                  item.frame.contains(currentPoint) else { return }
            self.hoverIdentity = DockHoverIdentity(item: item, dockPID: pid, point: point, readAt: now)
        }
    }

    private func recoverSourceFromDragboard(_ current: inout Gesture) {
        guard current.hasDragged, current.dockOriginConfirmed,
              DockAccessibility.dockProcessID == current.dockPID,
              let baseline = current.dragBoardChangeAtDown else { return }
        let board = NSPasteboard(name: .drag)
        let change = board.changeCount
        guard change != baseline, change != current.lastReadBoardChange else { return }
        current.lastReadBoardChange = change
        // 只读这一次新拖动的单个公开文件 URL；绝不触碰 general 剪贴板或其它类型内容。
        guard board.pasteboardItems?.count == 1,
              board.types?.contains(.fileURL) == true,
              let string = board.string(forType: .fileURL), string.utf8.count < 8192,
              let url = URL(string: string), url.isFileURL else {
            diagnostics.record(.dragboardUnsupported, numbers: ["change": Double(change), "baseline": Double(baseline)])
            return
        }
        guard let source = DockGestureRules.dragboardSource(candidate: current.source, urls: [url],
            baseline: baseline, change: change, dockConfirmed: current.dockOriginConfirmed,
            dockPID: current.dockPID, currentDockPID: current.dockPID,
            hasDragged: current.hasDragged, knownItems: current.initialItems) else {
            diagnostics.record(.dragboardRejected, source: current.source?.appURL, target: url)
            return
        }
        current.source = source
        current.sourceVerified = true
        diagnostics.record(.dragboardVerified, source: source.appURL,
            numbers: ["change": Double(change), "baseline": Double(baseline)])
    }

    private func refreshPointTargetIfNeeded(_ current: Gesture) {
        let now = ProcessInfo.processInfo.systemUptime
        guard pointReadTask == nil, now - lastPointReadAt >= 0.16,
              snapshot?.isComplete != true || current.target == nil else { return }
        lastPointReadAt = now
        let point = current.location
        let token = generation
        pointReadTask = Task { [weak self] in
            let item = await Task.detached(priority: .utility) {
                DockAccessibility.applicationItem(at: point, processID: current.dockPID)
            }.value
            guard let self, self.generation == token else { return }
            self.pointReadTask = nil
            guard var active = self.gesture, active.id == current.id,
                  hypot(active.location.x - point.x, active.location.y - point.y) < 5,
                  let item, item.appURL != active.source?.appURL,
                  DockGestureRules.item(at: point, in: [item], centralOnly: true) != nil else { return }
            active.pointTarget = item
            active.pointTargetTime = ProcessInfo.processInfo.systemUptime
            self.gesture = active
        }
    }

    private func emitFeedback(_ message: String?, at point: CGPoint) {
        guard message != lastFeedback || hypot(point.x - lastFeedbackPoint.x, point.y - lastFeedbackPoint.y) > 2 else { return }
        lastFeedback = message
        lastFeedbackPoint = point
        onHover(message, point)
    }
}


enum DockGestureDiagnosticReason: String, Codable {
    case started, stopped, startDeniedAX, startDeniedTap, tapDisabled, cancelledEscape
    case downModifiers, downNoDock, downNoCandidate, downCandidate
    case sourceRead, sourceMissing, sourceSuperseded, sourceRejected, sourceVerified, sourcePreverified
    case dragboardUnsupported, dragboardRejected, dragboardVerified, movedWithButton
    case dragWithoutGesture, dragModifiers, dragBegan, targetChanged, dwellReady
    case upWithoutGesture, released, upModifiers, upUnverifiedSource, upNoTarget, upDwellShort
    case commitWaiting, commitSuperseded, commitDockChanged, releaseNotDock, mergeDispatched, snapshotFailed
}

/// 诊断仅在用户/开发者创建 enabled 标记后启用；不记录键入、标题或原始应用路径。
@MainActor
private final class DockGestureDiagnostics {
    private struct Record: Encodable {
        let ms: Double
        let reason: DockGestureDiagnosticReason
        let x: Double?
        let y: Double?
        let source: String?
        let target: String?
        let numbers: [String: Double]
    }
    private struct Archive: Encodable {
        let version = 1
        let processID: Int32
        let startedAt: Date
        let counters: [String: Int]
        let snapshot: [String: Double]
        let records: [Record]
    }
    private let directory: URL?
    private let began = ProcessInfo.processInfo.systemUptime
    private let startedAt = Date()
    private var enabled = false
    private var lastPoll: TimeInterval = 0
    private var lastFlush: TimeInterval = 0
    private var dirty = false
    private var records: [Record] = []
    private var counters: [String: Int] = [:]
    private var snapshotValues: [String: Double] = [:]
    init(directory: URL?) { self.directory = directory; poll(force: true) }
    func poll(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPoll > 0.5 else { return }
        lastPoll = now
        enabled = directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("native-drag.enabled").path) } ?? false
        if enabled, dirty, now - lastFlush >= 0.5 { flush() }
    }
    func count(_ type: CGEventType) {
        guard enabled else { return }
        let key: String
        switch type {
        case .leftMouseDown: key = "mouseDown"
        case .leftMouseDragged: key = "mouseDragged"
        case .leftMouseUp: key = "mouseUp"
        case .keyDown: return // 不统计或存储普通键盘输入。
        default: return
        }
        counters[key, default: 0] += 1; dirty = true
    }
    func increment(_ reason: DockGestureDiagnosticReason) {
        guard enabled else { return }
        counters[reason.rawValue, default: 0] += 1; dirty = true
    }
    func record(_ reason: DockGestureDiagnosticReason, point: CGPoint? = nil, source: URL? = nil, target: URL? = nil,
                numbers: [String: Double] = [:]) {
        poll()
        guard enabled else { return }
        increment(reason)
        records.append(Record(ms: (ProcessInfo.processInfo.systemUptime - began) * 1000,
            reason: reason, x: point.map { Double($0.x.rounded()) }, y: point.map { Double($0.y.rounded()) },
            source: source.map(Self.identifier), target: target.map(Self.identifier), numbers: numbers))
        if records.count > 160 { records.removeFirst(records.count - 160) }
        dirty = true
    }
    func snapshot(count: Int, complete: Bool, milliseconds: Double) {
        guard enabled else { return }
        snapshotValues = ["count": Double(count), "complete": complete ? 1 : 0, "elapsedMS": milliseconds]
        dirty = true
    }
    private func flush() {
        guard let directory else { return }
        let archive = Archive(processID: ProcessInfo.processInfo.processIdentifier, startedAt: startedAt,
                              counters: counters, snapshot: snapshotValues, records: records)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(archive) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("native-drag.json"), options: .atomic)
            lastFlush = ProcessInfo.processInfo.systemUptime; dirty = false
        } catch { /* 可选诊断失败不影响输入。 */ }
    }
    private static func identifier(_ url: URL) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in url.path.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(value, radix: 16)
    }
}
