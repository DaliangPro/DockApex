import AppKit
import CoreGraphics
import ApplicationServices
@preconcurrency import ScreenCaptureKit

/// 系统仍持有真实 AXMinimized 状态；此组件只把窗口图像过渡到本工具的实际图标。
/// 只使用已授予的屏幕录制权限，图像仅保存在内存，不申请权限、不落盘。
@MainActor
final class DockMinimizationController {
    static var hasRequiredPermissions: Bool { CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() }

    private struct Snapshot {
        let applicationPath: String
        let windowID: String
        let cgWindowID: CGWindowID
        let processIdentity: String
        let image: CGImage
        let frame: CGRect
        let capturedAt: Date
    }

    struct TransitionDiagnostic: Sendable {
        let windowID: String
        let cgWindowID: CGWindowID
        let restoring: Bool
        let source: CGRect
        let target: CGRect
        let startedAt: Date
        let finishedAt: Date?

        var summary: String {
            "ax=\(windowID),cg=\(cgWindowID),kind=\(restoring ? "restore" : "minimize"),source=\(NSStringFromRect(source)),target=\(NSStringFromRect(target)),elapsedMs=\(Int((finishedAt ?? Date()).timeIntervalSince(startedAt) * 1000))"
        }
    }

    private let onTargetRect: (String, String?, CGPoint) -> CGRect?
    private let onAvailabilityChanged: (String?) -> Void
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private var windows: [SCWindow] = []
    private var enumeratedAt = Date.distantPast
    private var snapshots: [String: Snapshot] = [:]
    private var transitions: [UUID: WindowAnimationPanel] = [:]
    private var lastEvents: [String: Date] = [:]
    private var restoringWindows: Set<String> = []
    private var isRunning = false
    private var generation = 0
    private var consecutiveFailures = 0
    private var captureCursor = 0
    private var lastCapturePID: pid_t?
    private var lastCacheBeforeFailure = "无"
    private var lastEvent = "无"
    private(set) var lastError: String?
    private(set) var capturedWindowCount = 0
    private(set) var minimizedTransitionCount = 0
    private(set) var restoredTransitionCount = 0
    private(set) var animationStartCount = 0
    private(set) var animationFinishCount = 0
    private(set) var animationCancelledCount = 0
    private(set) var lastStartedTransition: TransitionDiagnostic?
    private(set) var lastSuccessfulTransition: TransitionDiagnostic?
    var diagnosticSummary: String {
        "screenCapture=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted()) running=\(isRunning) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) capturePID=\(lastCapturePID ?? 0) cached=\(snapshots.count) captured=\(capturedWindowCount) minimized=\(minimizedTransitionCount) restored=\(restoredTransitionCount) started=\(animationStartCount) finished=\(animationFinishCount) cancelled=\(animationCancelledCount) cache=[\(cacheMetadata)] failureCache=[\(lastCacheBeforeFailure)] lastEvent=[\(lastEvent)] lastStarted=[\(lastStartedTransition?.summary ?? "无")] lastSuccessful=[\(lastSuccessfulTransition?.summary ?? "无")] error=\(lastError ?? "无")"
    }

    private var cacheMetadata: String {
        snapshots.values.sorted { $0.cgWindowID < $1.cgWindowID }.map {
            "ax=\($0.windowID),cg=\($0.cgWindowID),ageMs=\(Int(Date().timeIntervalSince($0.capturedAt) * 1000))"
        }.joined(separator: ";")
    }

    init(onTargetRect: @escaping (String, String?, CGPoint) -> CGRect?, onAvailabilityChanged: @escaping (String?) -> Void) {
        self.onTargetRect = onTargetRect
        self.onAvailabilityChanged = onAvailabilityChanged
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.hasRequiredPermissions else {
            fail("未取得屏幕录制与辅助功能权限，保留系统原生最小化动画。")
            return false
        }
        generation += 1; isRunning = true; lastError = nil; consecutiveFailures = 0
        AppWindowService.shared.onMinimizationEvent = { [weak self] event in self?.receive(event) }
        AppWindowService.shared.animateRestore = { [weak self] app, window, completion in
            self?.restore(app: app, window: window, completion: completion) ?? false
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCapture() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        scheduleCapture()
        onAvailabilityChanged(nil)
        return true
    }

    func stop() {
        generation += 1; isRunning = false
        timer?.invalidate(); timer = nil
        captureTask?.cancel(); captureTask = nil
        AppWindowService.shared.onMinimizationEvent = nil
        AppWindowService.shared.animateRestore = nil
        for transition in Array(transitions.values) { transition.finishImmediately() }
        transitions.removeAll(); snapshots.removeAll(); windows.removeAll(); lastEvents.removeAll(); restoringWindows.removeAll()
    }

    private func fail(_ reason: String) {
        lastError = reason
        lastCacheBeforeFailure = cacheMetadata
        stop()
        // 调用方条件恢复 mineffect/genie-speed。无法捕获时不能留下无反馈的瞬间最小化。
        onAvailabilityChanged(reason)
    }

    private func scheduleCapture() {
        guard isRunning, captureTask == nil else { return }
        guard Self.hasRequiredPermissions else { fail("屏幕录制或辅助功能权限已失效，已停用自有窗口动画并归还原生动画。"); return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let zOrder = onScreen.enumerated().reduce(into: [CGWindowID: Int]()) { result, item in
            if (item.element[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
               let number = item.element[kCGWindowNumber as String] as? NSNumber { result[number.uint32Value] = item.offset }
        }
        let entries = AppWindowService.shared.cachedSnapshots
        var candidates: [(entry: AppWindowCacheEntry, info: AppWindowInfo)] = []
        for entry in entries where entry.snapshot.processIdentifier != getpid() {
            for info in entry.snapshot.windows where !info.isMinimized {
                guard let number = info.cgWindowID, zOrder[number] != nil else { continue }
                candidates.append((entry, info))
            }
        }
        candidates.sort { lhs, rhs in
            let leftFront = lhs.entry.snapshot.processIdentifier == frontPID
            let rightFront = rhs.entry.snapshot.processIdentifier == frontPID
            if leftFront != rightFront { return leftFront }
            if leftFront && lhs.info.isFocused != rhs.info.isFocused { return lhs.info.isFocused }
            return (zOrder[lhs.info.cgWindowID!] ?? Int.max) < (zOrder[rhs.info.cgWindowID!] ?? Int.max)
        }
        // 前台最多四窗，另取最多四个最靠前的其他可见窗口；黄色按钮不要求 App 先激活。
        let foreground = candidates.filter { $0.entry.snapshot.processIdentifier == frontPID }.prefix(4)
        let background = candidates.filter { $0.entry.snapshot.processIdentifier != frontPID }.prefix(4)
        candidates = Array(foreground) + Array(background)
        guard !candidates.isEmpty else { return }
        let candidate = candidates[captureCursor % candidates.count]
        captureCursor = (captureCursor + 1) % candidates.count
        let info = candidate.info
        let pid = candidate.entry.snapshot.processIdentifier
        let path = candidate.entry.application.path
        let identity = candidate.entry.processIdentity
        guard let number = info.cgWindowID else { return }
        lastCapturePID = pid
        let currentGeneration = generation
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == currentGeneration { captureTask = nil } }
            do {
                if Date().timeIntervalSince(enumeratedAt) > 2 || !windows.contains(where: { $0.windowID == number }) {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    guard isRunning, generation == currentGeneration, !Task.isCancelled else { return }
                    windows = content.windows; enumeratedAt = Date()
                }
                guard let window = windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == pid }) else { return }
                let quartzFrame = Self.currentQuartzFrame(windowID: number) ?? info.quartzFrame ?? window.frame
                guard quartzFrame.width > 20, quartzFrame.height > 20 else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = min(1, 1600 / max(quartzFrame.width, quartzFrame.height))
                config.width = max(1, Int(quartzFrame.width * scale)); config.height = max(1, Int(quartzFrame.height * scale))
                config.showsCursor = false; config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true; config.shouldBeOpaque = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard isRunning, generation == currentGeneration, !Task.isCancelled,
                      NativeDockRecovery.processIdentity(pid) == identity else { return }
                snapshots[info.id] = Snapshot(applicationPath: path, windowID: info.id, cgWindowID: number,
                    processIdentity: identity, image: image, frame: Self.appKitRect(quartzFrame), capturedAt: Date())
                capturedWindowCount += 1; consecutiveFailures = 0
                if snapshots.count > 8, let oldest = snapshots.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key { snapshots[oldest] = nil }
            } catch {
                guard isRunning, generation == currentGeneration, !Task.isCancelled else { return }
                consecutiveFailures += 1
                if consecutiveFailures >= 3 { fail("窗口图像连续捕获失败，已归还原生最小化动画。\(error.localizedDescription)") }
            }
        }
    }

    private func receive(_ event: AppWindowMinimizationEvent) {
        guard isRunning, event.isMinimized else { return }
        if let previous = lastEvents[event.windowID], event.occurredAt.timeIntervalSince(previous) < 0.15 { return }
        lastEvents[event.windowID] = event.occurredAt
        lastEvent = "ax=\(event.windowID),rawAX=\(event.notificationWindowID),cg=\(event.cgWindowID ?? 0),frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"
        guard let snapshot = validSnapshot(windowID: event.windowID, appPath: event.application.path, cgWindowID: event.cgWindowID),
              event.occurredAt.timeIntervalSince(snapshot.capturedAt) < 3 else {
            fail("本次窗口截图尚未就绪或已过期；event=[\(lastEvent)] cache=[\(cacheMetadata)]；未播放错误图像，已归还原生最小化动画。")
            return
        }
        guard let target = onTargetRect(event.application.path, event.windowID, CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY)) else {
            fail("未找到此窗口在当前显示器上的 Dock 入口，已归还原生最小化动画。")
            return
        }
        minimizedTransitionCount += 1
        animate(snapshot, target: target, restoring: false, completion: {})
    }

    private func restore(app: AppReference, window: AppWindowInfo, completion: @escaping () -> Void) -> Bool {
        if restoringWindows.contains(window.id) { return true }
        guard isRunning, let snapshot = validSnapshot(windowID: window.id, appPath: app.path, cgWindowID: window.cgWindowID),
              let target = onTargetRect(app.path, window.id, CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY)) else { return false }
        restoredTransitionCount += 1
        restoringWindows.insert(window.id)
        // 真实窗口在过渡完成前维持最小化；完成后由 AppWindowService 执行 AX 恢复。
        animate(snapshot, target: target, restoring: true) { [weak self] in
            self?.restoringWindows.remove(window.id)
            completion()
        }
        return true
    }

    private func validSnapshot(windowID: String, appPath: String, cgWindowID: CGWindowID?) -> Snapshot? {
        guard let snapshot = snapshots[windowID] ?? snapshots.values.first(where: { cgWindowID != nil && $0.cgWindowID == cgWindowID && $0.applicationPath == appPath }), snapshot.applicationPath == appPath,
              let pidText = windowID.split(separator: ":").first, let pid = pid_t(pidText),
              NativeDockRecovery.processIdentity(pid) == snapshot.processIdentity else { return nil }
        return snapshot
    }

    private func animate(_ snapshot: Snapshot, target: CGRect, restoring: Bool, completion: @escaping () -> Void) {
        let id = UUID()
        let startedAt = Date()
        animationStartCount += 1
        lastStartedTransition = TransitionDiagnostic(windowID: snapshot.windowID, cgWindowID: snapshot.cgWindowID,
            restoring: restoring, source: snapshot.frame, target: target, startedAt: startedAt, finishedAt: nil)
        let panel = WindowAnimationPanel(image: snapshot.image, source: snapshot.frame, target: target, restoring: restoring)
        transitions[id] = panel
        panel.play { [weak self] completed in
            if let self {
                transitions[id] = nil
                if completed {
                    animationFinishCount += 1
                    lastSuccessfulTransition = TransitionDiagnostic(windowID: snapshot.windowID, cgWindowID: snapshot.cgWindowID,
                        restoring: restoring, source: snapshot.frame, target: target, startedAt: startedAt, finishedAt: Date())
                } else { animationCancelledCount += 1 }
            }
            completion()
        }
    }

    private static func currentQuartzFrame(windowID: CGWindowID) -> CGRect? {
        guard let items = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = items.first?[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private static func appKitRect(_ rect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// 无激活、无鼠标事件的独立图像窗；不缩放或移动真正的第三方应用窗口。
@MainActor
private final class WindowAnimationPanel: NSPanel {
    private let imageLayer = CALayer()
    private let sourceRect: CGRect
    private let targetRect: CGRect
    private let restoring: Bool
    private var completion: ((Bool) -> Void)?
    private var finishTask: Task<Void, Never>?

    init(image: CGImage, source: CGRect, target: CGRect, restoring: Bool) {
        self.restoring = restoring
        let canvas = source.union(target).insetBy(dx: -14, dy: -14)
        sourceRect = source.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        targetRect = target.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        super.init(contentRect: canvas, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if #available(macOS 26.0, *) { collectionBehavior.insert(.canJoinAllApplications) }
        animationBehavior = .none; isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: canvas.size))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.clear.cgColor
        view.setAccessibilityElement(false)
        contentView = view
        imageLayer.contents = image; imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = true; imageLayer.cornerRadius = 12
        imageLayer.frame = restoring ? targetRect : sourceRect
        view.layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档载入动画窗") }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func play(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        orderFrontRegardless()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.13 : 0.32
        let from = restoring ? targetRect : sourceRect
        let to = restoring ? sourceRect : targetRect
        let points = CAKeyframeAnimation(keyPath: "position")
        let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
        let path = CGMutablePath(); path.move(to: start)
        let bend = CGPoint(x: start.x + (end.x - start.x) * 0.68, y: start.y + (end.y - start.y) * 0.3)
        path.addQuadCurve(to: end, control: bend)
        points.path = path; points.calculationMode = .paced
        let size = CABasicAnimation(keyPath: "bounds")
        size.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        size.toValue = NSValue(rect: CGRect(origin: .zero, size: to.size))
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = restoring ? [0.3, 1, 1] : [1, 1, 0]
        opacity.keyTimes = restoring ? [0, 0.15, 1] : [0, 0.85, 1]
        let group = CAAnimationGroup(); group.animations = [points, size, opacity]
        group.duration = duration; group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false; group.fillMode = .forwards
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.position = end; imageLayer.bounds = CGRect(origin: .zero, size: to.size)
        imageLayer.opacity = restoring ? 1 : 0
        CATransaction.commit()
        imageLayer.add(group, forKey: "窗口过渡")
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.finishImmediately(completed: true)
        }
    }

    func finishImmediately(completed: Bool = false) {
        finishTask?.cancel(); finishTask = nil
        orderOut(nil); imageLayer.removeAllAnimations()
        let action = completion; completion = nil
        action?(completed)
    }
}
