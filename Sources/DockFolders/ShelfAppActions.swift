import AppKit

/// 每次用户点击都开启一个操作代次；异步读取、动画和启动回调共享它。
/// 用户切到其他应用后，旧回调仍可完成读取，但不得再激活或隐藏应用。
struct ShelfInteractionToken: Equatable, Sendable { fileprivate let generation: UInt64 }

struct ShelfApplicationIdentity: Equatable, Sendable {
    let pid: pid_t
    let launchTime: TimeInterval?
    let path: String?

    @MainActor init(_ application: NSRunningApplication) {
        pid = application.processIdentifier
        launchTime = application.launchDate?.timeIntervalSince1970
        path = application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    init(pid: pid_t, launchTime: TimeInterval?, path: String?) {
        self.pid = pid; self.launchTime = launchTime; self.path = path
    }
}

/// 与 NSWorkspace 分离的状态规则，便于验证迟到回调与真实焦点切换。
struct ShelfInteractionState {
    private var generation: UInt64 = 0
    private var targetPath: String?
    private var initial: ShelfApplicationIdentity?
    private var targetBecameFrontmost = false
    private var valid = false

    mutating func begin(targetPath: String, initial: ShelfApplicationIdentity?) -> ShelfInteractionToken {
        generation &+= 1
        self.targetPath = targetPath; self.initial = initial
        targetBecameFrontmost = initial?.path == targetPath
        valid = true
        return ShelfInteractionToken(generation: generation)
    }

    mutating func permits(_ token: ShelfInteractionToken, frontmost: ShelfApplicationIdentity?, ownPID: pid_t) -> Bool {
        guard token.generation == generation, valid else { return false }
        guard let frontmost else { return true }
        if frontmost.path == targetPath { targetBecameFrontmost = true; return true }
        // 非激活面板不会夺取原应用；管理窗口内点击时本进程也可以作为起点。
        if !targetBecameFrontmost, frontmost == initial { return true }
        if frontmost.pid == ownPID, initial?.pid == ownPID, !targetBecameFrontmost { return true }
        valid = false
        return false
    }

    mutating func observe(_ frontmost: ShelfApplicationIdentity, ownPID: pid_t) -> Bool {
        permits(ShelfInteractionToken(generation: generation), frontmost: frontmost, ownPID: ownPID)
    }
}

@MainActor
final class ShelfInteractionCoordinator {
    static let shared = ShelfInteractionCoordinator()
    private var state = ShelfInteractionState()
    private var operation: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let identity = MainActor.assumeIsolated { ShelfApplicationIdentity(application) }
            Task { @MainActor [weak self] in
                guard let self, NSWorkspace.shared.frontmostApplication.map(ShelfApplicationIdentity.init) == identity else { return }
                if !state.observe(identity, ownPID: ProcessInfo.processInfo.processIdentifier) { operation?.cancel(); operation = nil }
            }
        }
    }

    func begin(_ app: AppReference) -> ShelfInteractionToken {
        operation?.cancel(); operation = nil
        return state.begin(targetPath: app.path, initial: NSWorkspace.shared.frontmostApplication.map(ShelfApplicationIdentity.init))
    }

    func permits(_ token: ShelfInteractionToken) -> Bool {
        state.permits(token, frontmost: NSWorkspace.shared.frontmostApplication.map(ShelfApplicationIdentity.init),
                      ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    func track(_ task: Task<Void, Never>, for token: ShelfInteractionToken) {
        guard permits(token) else { task.cancel(); return }
        operation?.cancel(); operation = task
    }
}

/// NSRunningApplication 的 false 返回值不代表目标状态没有发生；先给工作区事件完成递送。
@MainActor
enum ShelfAppActionVerification {
    static func shouldReportFailure(isCurrent: () -> Bool, hasReachedState: () -> Bool, permits: () -> Bool,
                                    wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) }) async -> Bool {
        guard !Task.isCancelled, permits(), isCurrent(), !hasReachedState() else { return false }
        do { try await wait() } catch { return false }
        return !Task.isCancelled && permits() && isCurrent() && !hasReachedState()
    }
}

@MainActor
enum ShelfAppActions {
    static func running(_ app: AppReference) -> NSRunningApplication? {
        ShelfRunningApplications.shared.running(app)
    }

    static func icon(_ app: AppReference) -> NSImage {
        DockIconProvider.shared.icon(for: app)
    }

    static func open(_ app: AppReference, modifiers: NSEvent.ModifierFlags = []) {
        let interaction = ShelfInteractionCoordinator.shared.begin(app)
        let relevant = modifiers.intersection([.command, .option])
        if relevant == .command {
            NSWorkspace.shared.activateFileViewerSelecting([app.appURL])
            return
        }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousIdentity = previousApplication.map(ShelfApplicationIdentity.init)
        let previousProcessIdentity = previousApplication.flatMap { ShelfRunningProcessIdentity.capture($0.processIdentifier) }
        if relevant == .option, let target = running(app), target.isActive {
            target.hide()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // 保留 reopen 事件（包括无窗口应用），但由仍然有效的回调决定是否激活。
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        // 启动器拉起的主程序正在运行时直接打开主程序，与点按运行中的 App 一样；没在运行时仍经过启动器，保留它的更新流程。
        let target = running(app).flatMap { ShelfRunningApplications.shared.reference(forPID: $0.processIdentifier) } ?? app
        NSWorkspace.shared.openApplication(at: target.appURL, configuration: configuration) { opened, error in
            let message = error?.localizedDescription
            let openedPID = opened?.processIdentifier
            Task { @MainActor in
                guard ShelfInteractionCoordinator.shared.permits(interaction) else { return }
                if let message { showError(title: "无法打开“\(app.name)”", message: message); return }
                if let openedPID, let opened = NSRunningApplication(processIdentifier: openedPID) {
                    ShelfRunningApplications.shared.register(opened)
                }
                guard let target = running(app), target.processIdentifier == openedPID else { return }
                target.unhide(); NSApp.yieldActivation(to: target); target.activate()
                if relevant == [.command, .option] {
                    for reference in ShelfRunningApplications.shared.regularReferences {
                        guard let candidate = running(reference), candidate.processIdentifier != openedPID else { continue }
                        candidate.hide()
                    }
                } else if relevant == .option, let previousApplication, let previousIdentity,
                          let previousProcessIdentity,
                          ShelfRunningProcessIdentity.capture(previousApplication.processIdentifier) == previousProcessIdentity,
                          ShelfApplicationIdentity(previousApplication) == previousIdentity,
                          previousApplication.processIdentifier != openedPID,
                          previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previousApplication.hide()
                }
                AppWindowService.shared.restoreIfAllMinimized(app, interaction: interaction)
            }
        }
    }

    static func openFiles(_ urls: [URL], with app: AppReference) {
        guard !urls.isEmpty else { return }
        let interaction = ShelfInteractionCoordinator.shared.begin(app)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open(urls, withApplicationAt: app.appURL, configuration: configuration) { opened, error in
            let message = error?.localizedDescription
            let openedPID = opened?.processIdentifier
            Task { @MainActor in
                guard ShelfInteractionCoordinator.shared.permits(interaction) else { return }
                if let message { showError(title: "“\(app.name)”无法打开这些项目", message: message) }
                else {
                    if let openedPID, let opened = NSRunningApplication(processIdentifier: openedPID) {
                        ShelfRunningApplications.shared.register(opened)
                    }
                    if let target = running(app) { target.unhide(); NSApp.yieldActivation(to: target); target.activate() }
                }
            }
        }
    }

    /// 顺序与原生 Dock 一致：打开与窗口在上，选项类在中间（`extraItems` 接在“在 Finder 中显示”之后），
    /// 隐藏、退出、强制退出放在最下面。
    static func applicationMenu(_ app: AppReference, extraItems: [NSMenuItem] = [], allowRemoval: Bool = false,
                                onRemove: (() -> Void)? = nil, onActivate: (() -> Void)? = nil) -> NSMenu {
        let menu = ShelfApplicationMenu(application: app, onWindowSelected: onActivate)
        menu.addItem(ShelfMenuItem("打开 / 切换") { open(app); onActivate?() })
        let target = running(app)
        // 常用窗口直接出现在当前菜单，菜单打开后的 AX 更新也在原处补全。
        if target != nil { menu.installCachedWindows() }
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.appURL]) })
        for item in extraItems { menu.addItem(item) }
        if allowRemoval, let onRemove { menu.addItem(ShelfMenuItem("从应用栏移除", handler: onRemove)) }
        if let target {
            menu.addItem(.separator())
            menu.addItem(ShelfMenuItem(target.isHidden ? "显示" : "隐藏") {
                let interaction = ShelfInteractionCoordinator.shared.begin(app)
                guard ShelfRunningApplications.shared.isCurrent(target) else { return }
                if target.isHidden { open(app) }
                else if !target.hide() {
                    reportUnfulfilledAction(target, interaction: interaction, hasReachedState: { target.isHidden },
                        title: "未能隐藏“\(app.name)”", message: "应用仍未隐藏，请稍后重试。")
                }
            })
            if app.bundleIdentifier != "com.apple.finder" {
                menu.addItem(ShelfMenuItem("退出") {
                    let interaction = ShelfInteractionCoordinator.shared.begin(app)
                    guard ShelfRunningApplications.shared.isCurrent(target) else { return }
                    if !target.terminate() {
                        reportUnfulfilledAction(target, interaction: interaction, hasReachedState: { target.isTerminated },
                            title: "“\(app.name)”尚未退出", message: "请检查应用是否有待处理的确认对话框；必要时可使用强制退出。")
                    }
                })
                menu.addItem(ShelfMenuItem("强制退出…") {
                    guard ShelfRunningApplications.shared.isCurrent(target) else { return }
                    forceQuit(app)
                })
            }
        }
        return menu
    }

    static func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    static func forceQuit(_ app: AppReference) {
        _ = ShelfInteractionCoordinator.shared.begin(app)
        guard let running = running(app) else { return }
        let alert = NSAlert()
        alert.messageText = "强制退出“\(app.name)”？"
        alert.informativeText = "尚未保存的更改可能会丢失。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "强制退出")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn,
           let current = self.running(app), current === running,
           ShelfRunningApplications.shared.isCurrent(current) {
            let interaction = ShelfInteractionCoordinator.shared.begin(app)
            if !current.forceTerminate() {
                reportUnfulfilledAction(current, interaction: interaction, hasReachedState: { current.isTerminated },
                    title: "“\(app.name)”尚未退出", message: "强制退出后应用仍在运行，请稍后重试。")
            }
        }
    }

    private static func reportUnfulfilledAction(_ target: NSRunningApplication, interaction: ShelfInteractionToken,
                                                hasReachedState: @escaping @MainActor () -> Bool,
                                                title: String, message: String) {
        let task = Task { @MainActor in
            guard await ShelfAppActionVerification.shouldReportFailure(
                isCurrent: { ShelfRunningApplications.shared.isCurrent(target) }, hasReachedState: hasReachedState,
                permits: { ShelfInteractionCoordinator.shared.permits(interaction) }) else { return }
            showError(title: title, message: message)
        }
        ShelfInteractionCoordinator.shared.track(task, for: interaction)
    }

    static func groupIcon(_ group: AppGroup) -> NSImage {
        DockIconProvider.shared.groupIcon(for: group)
    }
}

@MainActor
/// 菜单里的一行滑块：左边标题、右边滑块，拖动时连续回调，松手时 finished 为 true。
/// 设置菜单用它调应用栏的大小与放大，对应系统设置里程序坞的两个滑块。
final class ShelfMenuSlider: NSView {
    let slider: NSSlider
    private let handler: (Double, Bool) -> Void

    init(title: String, value: Double, range: ClosedRange<Double>, handler: @escaping (Double, Bool) -> Void) {
        self.handler = handler
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(title)
        for view in [label, slider] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 标题栏宽按四个字留足，两行的滑块左端对齐。
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 92),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func update(value: Double, range: ClosedRange<Double>) {
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value
    }

    @objc private func changed() { handler(slider.doubleValue, NSApp.currentEvent?.type == .leftMouseUp) }
}

final class ShelfMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("不支持从归档载入菜单") }
    @objc private func invoke() { handler() }
}
