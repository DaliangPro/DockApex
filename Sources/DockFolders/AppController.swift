import AppKit
import CoreGraphics
import Foundation

@main
struct DockFoldersMain {
    @MainActor static func main() {
        if NativeHostRecoveryCommand.runIfRequested() { return }
        if DockCalibrationCapture.runIfRequested() { return }
        if DockAutomation.runIfRequested() { return }
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(controller) {}
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: ShelfStore!
    private var nativeDock: NativeDockCoordinator!
    private var log: ActivityLog!
    private var statusItem: NSStatusItem!
    private var runtimeTimer: Timer?
    private var trashTimer: Timer?
    private var lastTrashIsEmpty: Bool?
    private var emptyingTrash = false
    private var runtimeObservers: [NSObjectProtocol] = []
    private var dockSettings: NativeDockSettingsWatcher?
    private lazy var fullscreenTracker = FullscreenTracker { [weak self] displays in
        self?.bar.setFullscreenDisplays(displays)
        self?.shadowDock.setFullscreenDisplays(displays)
    }
    private var nativeStatuses: [String: NativeDockItemStatus] = [:]
    private lazy var nativeStatusSource = NativeDockStatusSource { [weak self] statuses in
        self?.nativeStatuses = statuses
        self?.panel.updateBadges(statuses.compactMapValues(\.badge))
        self?.refreshBar()
    }
    private var displayItems: [ShelfItem] = []
    private var barItemIDs: [String] = []
    private var minimizedWindows: [String: (application: AppReference, window: AppWindowInfo)] = [:]
    private var lastHoveredWindowRefresh: [String: TimeInterval] = [:]
    private var status = "就绪：拖到图标边缘排序；拖到另一图标中央，出现预览后松开建组。"
    private let finderPath = "/System/Library/CoreServices/Finder.app"
    private let installedApplications = InstalledApplicationsMonitor()
    /// 引用的应用第一次发现不在原处的时间。更新程序替换应用包时路径会短暂消失：过了短宽限才去找装到别处的同一应用，
    /// 过了移除宽限仍不在就当作卸载移除（用户卸载后图标要尽快消失，原先等 10 分钟被当成 bug）。
    private var missingApplications: [String: TimeInterval] = [:]
    /// 自动移除的应用和它原来的位置。pkg 安装、大型更新可能先删旧包、几分钟后才放新包：30 分钟内同一应用装回来
    /// （原路径或按包名找到），就放回原来的固定位置或分组，不丢位置。
    private var removedApplications: [String: (app: AppReference, placement: ShelfPlacement, removedAt: TimeInterval)] = [:]
    private var applicationCheck: DispatchWorkItem?
    private static let missingApplicationGrace: TimeInterval = 5
    private static let missingApplicationRemoval: TimeInterval = 10
    private static let removedApplicationMemory: TimeInterval = 1800
    private var isEnding = false
    private var hasEnteredDock = false
    private var terminationTask: Task<Void, Never>?
    private let workArea = DockWorkAreaService()
    /// 悬浮条避让：每个 App 只在第一次挪动时记一条日志，免得语音条每次出现都记。
    private var floatingLogged = Set<String>()
    private lazy var floatingAvoidance = DockFloatingAvoidance(onMove: { [weak self] name, distance in
        Task { @MainActor [weak self] in
            guard let self, self.floatingLogged.insert(name).inserted else { return }
            self.log?.record(String(format: "悬浮窗避让：%@ 的浮窗伸进应用栏，挪开 %.0f 点", name, distance))
        }
    })
    private lazy var classicEdgeGuard = DockEdgeGuard(onDockMove: { [weak self] in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliverClassicEdgePointer() } }
    })
    private var relocatingHiddenDock = false
    /// 经典模式下藏着的系统 Dock 已确认所在的屏（显示器 UUID）。只有它就是应用栏所在屏时才读原生菜单：
    /// 菜单会弹在那块屏的底边上，遮盖也盖在那里。
    private var hiddenDockScreenUUID: String?
    private var hiddenDockAlignment: DispatchWorkItem?
    /// 最近一次对齐量过的布局，以及这个布局下量过的 图标尺寸 → 废纸篓横向差。布局不变就不再对齐；
    /// 量过且不比现在准的尺寸不再回去：尺寸只能取整数，理想值落在两个整数之间时会在两边来回改（10-23 实测累计 1069 次）。
    private var hiddenDockAlignedLayout = ""
    /// 本应用最后一次给藏着的系统 Dock 设的图标尺寸；读到别的值就是用户在系统设置里拖了“大小”滑块。
    private var hiddenTileSizeSet: Double?
    /// 上次读到的系统 Dock 图标尺寸（启动后第一次读到的只作基准，不当作用户改动）。
    private var lastSeenDockTileSize: Double?
    /// 用户最近一次拖“大小”滑块的时刻：停手 1.5 秒内不对齐，免得和滑块抢；跟随记录也等停手后再写一条。
    private var userTileSizeChangedAt: TimeInterval?
    private var nativeSettingsLog: DispatchWorkItem?
    private var hiddenDockErrors: [Double: Double] = [:]
    /// 对齐时最近一次量到的隐藏系统 Dock（仅诊断用；诊断随每次刷新写出，不能在主线程现读辅助功能）。
    private var hiddenDockSummary = ""
    private var lastRuntimeDiagnostics: Data?
    // 日常使用自制应用栏；原生承载只保留显式开发入口。
    private let usesNativeHost = ProcessInfo.processInfo.environment["DOCKFOLDERS_USE_NATIVE_HOST"] == "1"
    private var nativeHost: NativeDockHostController?
    private var entryRuntime: GroupEntryRuntimeCoordinator?
    private var systemRegion: DockSystemRegionController?
    private let shadowDock = ShadowDockController()
    private var regionWatchdog: URL?
    private var switchingNativeMode = false
    private var shadowUnavailable = false
    private var groupRequestsReady = false
    private var pendingGroupRequest: UUID?
    private var restoresNativeLayoutOnQuit = false
    private var nativeGroupPresentationGeneration = 0
    private var minimizationGeneration = 0
    // 本机实测原生动画没有被 genie-speed 抑制，桥接会造成双重动画。
    // 显式实验入口仅供受控夹具研究，日常运行不捕获窗口、不改动画偏好。
    private let usesExperimentalMinimization = ProcessInfo.processInfo.environment["DOCKFOLDERS_EXPERIMENTAL_MINIMIZATION"] == "1"
    private lazy var minimization: DockMinimizationController = DockMinimizationController(
        onTargetRect: { [weak self] path, windowID, point in self?.minimizationTarget(path: path, windowID: windowID, sourcePoint: point) },
        onAvailabilityChanged: { [weak self] reason in
            guard let self, let reason else { return }
            self.log?.record("窗口动画桥接：\(reason)")
            do { try self.nativeDock?.resumeNativeMinimizationAnimations() }
            catch { self.log?.record("恢复原生窗口动画失败：\(error.localizedDescription)") }
        })

    private lazy var bar = DockDisplayCoordinator(
        onOpen: { [weak self] id, point in self?.openItem(id, point: point) },
        onMerge: { [weak self] source, target in self?.merge(source, into: target) },
        onReorder: { [weak self] id, index in self?.reorder(id, insertion: index) },
        onExternalDrop: { [weak self] drop in self?.handleDrop(drop.urls, target: drop.targetID, applicationReference: drop.isApplicationReference, copyFiles: drop.copyFiles, insertion: drop.insertionIndex) },
        onContext: { [weak self] id in self?.contextMenu(id) ?? NSMenu() },
        onRemove: { [weak self] id in self?.removeItem(id) }
    )
    private lazy var panel: GroupPanelController = GroupPanelController(onChanged: { [weak self] group in self?.updateGroup(group) },
        onVisibility: { [weak self] visible in
            guard let self else { return }
            if !self.usesNativeHost { self.bar.setInteractionHold("group", active: visible) }
            if !visible { self.log?.record("收起分组：\(self.panel.lastDismissalReason)") }
        })
    private lazy var filesPanel: FileStackController = FileStackController(onVisibility: { [weak self] visible in
        guard let self else { return }
        if !self.usesNativeHost { self.bar.setInteractionHold("files", active: visible) }
        if !visible { self.log?.record("收起文件夹：\(self.filesPanel.lastDismissalReason)") }
    })
    private lazy var manager = ManageWindowController(
        onChanged: { [weak self] groups in self?.updateGroups(groups) },
        onDelete: { [weak self] id in self?.dissolveGroup(id) },
        onPermissions: { [weak self] in
            guard let self else { return }
            if self.usesNativeHost { self.restoresNativeLayoutOnQuit = true }
            self.quit()
        },
        onOpen: { [weak self] id in
            guard let self, let group = self.store.configuration.groups.first(where: { $0.id == id }) else { return }
            if self.usesNativeHost { self.showNativeGroup(group) }
            else { self.openItem(ShelfItem.group(id).id, point: .zero) }
        }, nativeHost: usesNativeHost
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let data = AppDataLocation.dataDirectory
            // 安装版第一次运行时“应用支持”里还没有这个目录；先建好，日志才写得进去。
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            log = ActivityLog(root: data)
            // 同一时间只能有一份在管系统 Dock。会话互斥只看本 Data 目录，另一份构建（例如公开仓库的克隆）的 Data 在别处：
            // 两份同时运行会把对方改过的自动隐藏、图标尺寸记成原值，都退出后系统 Dock 停在隐藏状态。
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0.processIdentifier != getpid() }) {
                log.record("另一份 DockApex 正在运行（\(other.bundleURL?.path ?? "pid \(other.processIdentifier)")），本份不启动。")
                isEnding = true
                NSApp.terminate(nil)
                return
            }
            MainThreadStallMonitor.shared.start { [weak self] message in self?.log.record(message) }
            // 先恢复没有主进程的旧会话；即便布局文件损坏，也不会让旧的隐藏状态遗留。
            let recovery = NativeDockRecovery.Location(dataDirectory: data)
            if FileManager.default.fileExists(atPath: recovery.state.path) {
                try NativeDockRecovery.withLock(at: recovery) {
                    let session = try NativeDockRecovery.load(recovery.state)
                    if session.phase != .inactive && !NativeDockRecovery.ownerIsAlive(session) {
                        try NativeDockRecovery.restoreLocked(at: recovery, expectedID: session.id)
                    }
                }
            }
            store = try ShelfStore(root: data, initial: importNativeApplications())
            lastTrashIsEmpty = trashIsEmpty
            var migrated = store.configuration
            if migrated.options == nil { migrated.options = nativeOptions() }
            if migrated.files == nil { migrated.files = nativeFiles() }
            if migrated.recentApplications == nil { migrated.recentApplications = [] }
            try store.save(migrated, recordUndo: false)
            try store.save(store.configuration, recordUndo: false)
            guard let watchdog = Bundle.main.url(forResource: "DockRestoreAgent", withExtension: nil) else {
                throw DockFoldersError.message("缺少系统 Dock 恢复程序，请重新构建。")
            }
            nativeDock = NativeDockCoordinator(dataDirectory: data, watchdogExecutable: watchdog)
            makeMenus()
            if usesNativeHost {
                guard let proxy = Bundle.main.url(forResource: "GroupEntry", withExtension: nil) else {
                    throw DockFoldersError.message("缺少分组启动器，请重新构建。")
                }
                let host = try NativeDockHostController(dataDirectory: data, mainAppURL: Bundle.main.bundleURL,
                    proxyExecutable: proxy,
                    onMerge: { [weak self] source, target in self?.merge(source, into: target) },
                    onStatus: { [weak self] status in self?.setStatus(status) },
                    onItemsChanged: { [weak self] in self?.refreshBar() })
                nativeHost = host
                try host.install(groups: store.configuration.groups)
                let runtime = GroupEntryRuntimeCoordinator(dataDirectory: data)
                entryRuntime = runtime
                runtime.synchronize(groups: store.configuration.groups)
                host.start()
                installRuntimeObservers()
                refreshBar()
                log.record("原生 Dock 承载已启用；不创建独立栏、不调整应用窗口、不捕获屏幕。")
                finishGroupRequestStartup()
                return
            }
            // 先归还原生承载拥有的固定项，再隐藏系统 Dock，避免两种模式同时持有恢复会话。
            if FileManager.default.fileExists(atPath: data.appendingPathComponent("native-host-session.plist").path),
               let proxy = Bundle.main.url(forResource: "GroupEntry", withExtension: nil) {
                let host = try NativeDockHostController(dataDirectory: data, mainAppURL: Bundle.main.bundleURL,
                    proxyExecutable: proxy, onMerge: { _, _ in }, onStatus: { [weak self] in self?.setStatus($0) })
                try host.restoreOriginalIfUnchanged()
            }
            GroupEntryRuntimeCoordinator.stopOwnedEntries(dataDirectory: data)
            workArea.onChange = { [weak self] _ in self?.writeRuntimeDiagnostics() }
            workArea.onEvent = { [weak self] event in
                let name = NSRunningApplication(processIdentifier: event.pid)?.localizedName ?? "pid \(event.pid)"
                self?.log.record("窗口避让：\(name) \(event.text)")
            }
            bar.onGeometryChanged = { [weak self] in self?.updateWorkArea() }
            bar.onPresentationChanged = { [weak self] in
                guard let self else { return }
                self.shadowDock.setBarVisible(self.bar.isAnyBarPresented)
                self.shadowDock.setNear(self.bar.isAnyBarNear)
                self.shadowDock.setHovering(self.bar.isAnyBarHovered)
                self.floatingAvoidance.setHeldWhileHovering(self.bar.isAnyBarHovered)
                if self.bar.isAnyBarHovered { self.refreshHoveredWindowCaches() }
            }
            bar.onMenuState = { [weak self] open in self?.shadowDock.setMenuOpen(open) }
            if let host = Bundle.main.url(forResource: "DockTileHost", withExtension: nil) {
                DockTilePluginService.shared.configure(directory: data.appendingPathComponent("DockTiles", isDirectory: true), helper: host)
                DockTilePluginService.shared.onChange = { [weak self] path in self?.dockTileChanged(path) }
            }
            refreshBar()
            if let store, let group = store.configuration.groups.first { panel.prewarm(group) }
            regionWatchdog = watchdog
            try enterNativeMode()
            hasEnteredDock = true
            updateWorkArea()
            workArea.start()
            floatingAvoidance.onWindowEvent = { [weak self] in self?.workArea.requestWindowUpdate() }
            floatingAvoidance.startObserving()
            installRuntimeObservers()
            dockSettings = NativeDockSettingsWatcher { [weak self] values in
                Task { @MainActor [weak self] in self?.followNativeSettings(values) }
            }
            dockSettings?.start()
            // 系统设置在前台时直接向系统 Dock 实时读，拖滑块时应用栏跟着变；离开系统设置就停。
            let settingsID = "com.apple.systempreferences"
            dockSettings?.setLive(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == settingsID)
            runtimeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let active = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == settingsID
                MainActor.assumeIsolated { self?.dockSettings?.setLive(active) }
            })
            ShelfRunningApplications.shared.onRegularTerminated = { [weak self] app in self?.rememberRecentApplication(app) }
            ShelfRunningApplications.shared.onChange = { [weak self] in
                guard let self, !self.isEnding, self.terminationTask == nil else { return }
                self.pruneRecentApplications()
                self.refreshBar()
                self.refreshWindowCaches()
            }
            pruneRecentApplications()
            DockMotionSurface.onHoverChanged = { [weak self] id in self?.barHoverChanged(id) }
            WindowPreviewController.shared.onShown = { [weak self] in self?.bar.hideNameHints(); self?.panel.hideMemberNameHint() }
            DockMotionSurface.openGroupTarget = { [weak self] in
                guard let self, let id = self.panel.currentGroupID, let frame = self.panel.presentedFrame else { return nil }
                return (ShelfItem.group(id).id, frame)
            }
            GroupPanelController.log = { [weak self] message in self?.log.record(message) }
            DockMotionSurface.logDrop = { [weak self] message in self?.log.record(message) }
            DockMotionSurface.previewGroupIncoming = { [weak self] point in self?.panel.previewIncoming(at: point) }
            DockMotionSurface.groupIncomingLanding = { [weak self] in self?.panel.incomingLandingRect() }
            GroupPanelController.referenceDragMoved = { [weak self] point in self?.bar.updateReferenceDrag(at: point) }
            GroupPanelController.referenceDropped = { [weak self] url, point in self?.bar.dropReference(url, at: point) ?? false }
            nativeStatusSource.start()
            fullscreenTracker.start()
            AppWindowService.shared.onChange = { [weak self] minimizedChanged in
                if minimizedChanged { self?.refreshBar() }
                self?.workArea.requestWindowUpdate()
            }
            refreshWindowCaches()
            if usesExperimentalMinimization { minimization.start() }
            log.record("窗口动画状态：\(minimization.diagnosticSummary)")
            writeRuntimeDiagnostics()
            finishGroupRequestStartup()
            log.record("独立应用栏启动；布局 \(store.configuration.items.count) 个入口；\(store.configuration.groups.count) 个分组")
            if let message = LoginItemService.registerOnFirstLaunch() { log.record(message) }
            runtimeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowCaches(); self?.refreshBar() }
            }
            // 访达改变废纸篓状态时只改系统 Dock 的偏好、不发通知；每 0.5 秒在后台看一次（同步偏好要等 cfprefsd），
            // 变了才回主线程重画。
            trashTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async {
                    let empty = AppController.readTrashIsEmpty()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, empty != self.lastTrashIsEmpty else { return }
                            self.lastTrashIsEmpty = empty
                            self.log.record("废纸篓变为\(empty == true ? "空" : empty == false ? "满" : "未知")")
                            self.refreshBar()
                        }
                    }
                }
            }
            installedApplications.onChange = { [weak self] paths in self?.installedApplicationsChanged(paths) }
            // 启动时也核对一次：应用没运行期间卸载、移动的应用同样要处理。
            scheduleApplicationCheck(after: 1)
        } catch {
            entryRuntime?.stop()
            nativeHost?.stop()
            shadowDock.stop(); classicEdgeGuard.setZones(edges: [], dock: [])
            _ = systemRegion?.stopAndRestore()
            try? nativeDock?.restore()
            if !usesNativeHost { bar.hide() }
            showError(error)
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let id = urls.reversed().compactMap({ url -> UUID? in
            guard url.scheme == "dockfolders", url.host == "group" else { return nil }
            return UUID(uuidString: url.lastPathComponent)
        }).first else { return }
        // 系统可在 didFinishLaunching 之前投递打开事件；不能在 store 尚未就绪时丢掉首次单击。
        guard groupRequestsReady else { pendingGroupRequest = id; return }
        openRequestedGroup(id)
    }

    private func finishGroupRequestStartup() {
        groupRequestsReady = true
        guard let id = pendingGroupRequest else { return }
        pendingGroupRequest = nil
        DispatchQueue.main.async { [weak self] in self?.openRequestedGroup(id) }
    }

    private func openRequestedGroup(_ id: UUID) {
        guard !isEnding, let group = store?.configuration.groups.first(where: { $0.id == id }) else { return }
        if usesNativeHost { showNativeGroup(group) }
        else { openItem(ShelfItem.group(group.id).id, point: CGEvent(source: nil)?.location ?? .zero) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationTask != nil { return .terminateLater }
        guard !isEnding else { return .terminateNow }
        if usesNativeHost {
            do {
                if restoresNativeLayoutOnQuit { try nativeHost?.restoreOriginalIfUnchanged() }
                entryRuntime?.stop()
                nativeHost?.stop()
                isEnding = true
                return .terminateNow
            } catch {
                restoresNativeLayoutOnQuit = false
                showError(error)
                return .terminateCancel
            }
        }
        ShadowDockGeometry.cancelPush()
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.minimization.stop()
            self.shadowDock.stop(); self.classicEdgeGuard.setZones(edges: [], dock: [])
            self.floatingAvoidance.stop()
            await self.workArea.stopAndRestore()
            _ = self.systemRegion?.stopAndRestore()
            do {
                try self.nativeDock?.restore()
                self.isEnding = true
                self.terminationTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                self.terminationTask = nil
                _ = self.systemRegion?.start(areas: self.bar.visibleDockAreas, preferredDisplayUUID: self.bar.activeDisplayUUID)
                if self.nativeDock.shadow != nil { self.shadowDock.start() }
                self.updateWorkArea()
                self.workArea.start()
                self.showError(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 没启动起来（例如另一份已在运行）就什么都不碰，免得为收尾现建面板、记一条误导的“已恢复”。
        guard store != nil else { return }
        ShelfRunningApplications.shared.onChange = nil
        ShelfRunningApplications.shared.stop()
        if usesNativeHost {
            entryRuntime?.stop()
            nativeHost?.stop()
            AppWindowService.shared.stopObserving()
            panel.hide(animated: false)
            log?.record("原生承载工具正常退出；系统 Dock 继续管理工作区。")
            return
        }
        runtimeTimer?.invalidate(); trashTimer?.invalidate()
        nativeStatusSource.stop()
        fullscreenTracker.stop()
        AppWindowService.shared.stopObserving()
        minimization.stop()
        panel.hide(animated: false)
        filesPanel.hide(animated: false)
        bar.hide()
        log?.record("正常退出，系统 Dock 已恢复")
    }

    private func importNativeApplications() -> ShelfConfiguration {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        var apps = tiles.compactMap { tile -> AppReference? in
            guard let url = DockLayout.appURL(in: tile), var app = AppReference(url: url) else { return nil }
            if let label = (tile["tile-data"] as? [String: Any])?["file-label"] as? String, !label.isEmpty { app.name = label }
            return app
        }
        apps.removeAll { $0.path.contains("/Data/Entries/") || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        if let finder = AppReference(url: URL(fileURLWithPath: finderPath)) {
            apps.removeAll { $0.path == finder.path }
            apps.insert(finder, at: 0)
        }
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        return ShelfConfiguration(items: apps.map(ShelfItem.app), position: DockPosition(rawValue: orientation ?? "bottom") ?? .bottom)
    }

    private func nativeOptions() -> ShelfOptions {
        func preference(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) }
        return ShelfOptions(iconSize: min(96, max(24, (preference("tilesize") as? Double) ?? 48)),
                            maximumIconSize: min(128, max(32, (preference("largesize") as? Double) ?? 64)),
                            magnification: (preference("magnification") as? Bool) ?? false,
                            showRunningIndicators: (preference("show-process-indicators") as? Bool) ?? true,
                            showRecentApplications: (preference("show-recents") as? Bool) ?? true,
                            animateLaunching: (preference("launchanim") as? Bool) ?? true,
                            minimizeToApplication: (preference("minimize-to-application") as? Bool) ?? false)
    }

    /// 系统设置里改了程序坞的大小、放大、运行指示、启动动画或最小化方式：经典模式下应用栏跟着变。
    /// 影子 Dock 会改写放大、退出时又写回原值，那些时候不跟随。不算一步可撤销的布局更改。
    private func followNativeSettings(_ values: NativeDockSettingsWatcher.Values) {
        guard let store, !usesNativeHost, canAdjustHiddenDock else { return }
        var next = store.configuration
        var options = next.options ?? nativeOptions()
        let before = options
        // “大小”：系统 Dock 的图标尺寸平时由本应用调来对准最小化落点。读到的既不是上次的值、也不是本应用设的值，
        // 就是用户拖了滑块：应用栏图标跟着变，停手后再把系统 Dock 调回对准落点的尺寸，滑块随之跳回（10-25 用户选定）。
        // 启动后第一次读到的只作基准。
        if let tile = values.tileSize {
            let previous = lastSeenDockTileSize
            lastSeenDockTileSize = tile
            if let previous, abs(tile - previous) >= 1, hiddenTileSizeSet.map({ abs(tile - $0) >= 1.5 }) ?? true {
                options.iconSize = min(max(tile, 16), 128)
                userTileSizeChangedAt = ProcessInfo.processInfo.systemUptime
                do { try nativeDock.updateOriginal("tilesize", to: tile) } catch { log?.record("未更新系统 Dock 图标尺寸的原值：\(error.localizedDescription)") }
            }
        }
        options.magnification = values.magnification
        options.maximumIconSize = max(values.largeSize, options.iconSize)
        options.showRunningIndicators = values.showRunningIndicators
        options.animateLaunching = values.animateLaunching
        // 没存过（nil）与关等价，不为它多存一次。
        if (before.minimizeToApplication == true) != values.minimizeToApplication { options.minimizeToApplication = values.minimizeToApplication }
        guard options != before else { return }
        next.options = options
        do { try store.save(next, recordUndo: false) } catch { log?.record("跟随系统设置失败：\(error.localizedDescription)"); return }
        refreshBar()
        // 拖滑块时每 0.2 秒都可能变一次，记录等停下 1 秒后写一条。
        nativeSettingsLog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let options = self.store?.configuration.options else { return }
            func onOff(_ value: Bool) -> String { value ? "开" : "关" }
            self.log?.record("系统设置里的程序坞选项变了，应用栏已跟随：大小 \(Int(options.iconSize)) 点、放大 \(onOff(options.magnification))"
                + "（\(Int(options.maximumIconSize)) 点）、运行指示 \(onOff(options.showRunningIndicators))、启动动画 \(onOff(options.animateLaunching))、"
                + "最小化到应用程序图标 \(onOff(options.minimizeToApplication == true))")
        }
        nativeSettingsLog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func nativeFiles() -> [ShelfFile] {
        let tiles = CFPreferencesCopyAppValue("persistent-others" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                  let value = file["_CFURLString"] as? String,
                  let url = value.hasPrefix("file:") ? URL(string: value) : (value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil) else { return nil }
            return ShelfFile(url: url)
        }
    }

    private func installRuntimeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        // 本机诊断入口：只把几何、帧时序和交互状态写入项目 Data/Diagnostics，不读取窗口内容。
        runtimeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.daliang.dockfolders.write-diagnostics"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastRuntimeDiagnostics = nil; self?.writeRuntimeDiagnostics() }
        })
        // 本机帧率自测：应用栏沿虚拟指针扫动 3 秒，不移动真实鼠标；结束后用诊断入口读帧时序。
        runtimeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.daliang.dockfolders.sweep-benchmark"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bar.runSweepBenchmark(duration: 3) }
        })
        // 本机验收：收起应用栏弹出的右键菜单。测试脚本弹出菜单后用它关掉，不用发按键、也不用点别处
        // （10-25 点应用栏空白处收菜单时，图标正在放大，点到了访达）。
        runtimeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.daliang.dockfolders.close-menus"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockMenuPopover.shared.close() }
        })
        // 分组图标先用了旧图（成员还没按当前外观预取好）时，预取完再刷新一次，换上新图。
        DockIconProvider.shared.onGroupIconsWarmed = { [weak self] in self?.refreshBar() }
        // 分组图标是按外观画好的位图，切换深浅色后重新取一次（通知早于外观生效，稍等再刷新）。
        runtimeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshBar() }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            runtimeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let appURL = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL
                let isLaunch = note.name == NSWorkspace.didLaunchApplicationNotification
                let invalidatesIcon = isLaunch || note.name == NSWorkspace.didTerminateApplicationNotification
                let changesRunningCache = note.name != NSWorkspace.activeSpaceDidChangeNotification && note.name != NSWorkspace.didWakeNotification
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if invalidatesIcon, let appURL {
                        DockIconProvider.shared.invalidate(appPath: appURL.standardizedFileURL.resolvingSymlinksInPath().path)
                    }
                    if self.usesNativeHost {
                        self.refreshWindowCaches()
                        self.writeRuntimeDiagnostics()
                        return
                    }
                    // 应用事件已由共享缓存合并刷新；此处只保留空间／唤醒事件的补充更新。
                    if !changesRunningCache {
                        self.refreshBar()
                        self.refreshWindowCaches()
                    }
                }
            })
        }
        runtimeObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.panel.hide(reason: "screen-parameters"); self?.filesPanel.hide(reason: "screen-parameters"); self?.refreshBar()
            }
        })
        // 只听真正的显示器重新配置：系统 Dock 显隐、预留区变化也会发屏幕参数通知，听那个会被自己挪屏触发。
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard let info, !flags.contains(.beginConfigurationFlag) else { return }
            let controller = Unmanaged<AppController>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.scheduleHiddenDockRecheck() } }
        }, Unmanaged.passUnretained(self).toOpaque())
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            runtimeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleHiddenDockRecheck() }
            })
        }
        // 系统 Dock 重启（崩溃或被系统重启）后也回到内建屏；刚启动的头两秒不响应开关与推边，等 3 秒。
        // 系统 Dock 由 launchd 拉起，不发应用启动通知（实测），只能看运行中应用列表的增项。
        dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        dockLaunchObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
                    guard let pid, pid != self.dockPID else { return }
                    self.dockPID = pid
                    self.scheduleHiddenDockRecheck(after: 3)
                }
            }
        }
    }
    private var dockLaunchObservation: NSKeyValueObservation?
    private var dockPID: pid_t?

    /// 经典模式：显示器重新配置（睡眠唤醒、插拔、改分辨率）或系统 Dock 重启后，它会回到内建屏；运行中改过它的
    /// 图标尺寸留下的强制显示还会让它露出来（10-19 实测：19:22 回到内建屏，22:42 唤醒后露出）。停稳后重新开启
    /// 自动隐藏（实测立即收起），不在应用栏所在屏就再挪过去。
    private var hiddenDockRecheck: DispatchWorkItem?
    private func scheduleHiddenDockRecheck(after delay: TimeInterval = 1.5) {
        guard hasEnteredDock, nativeDock.shadow == nil else { return }
        // 显示器重新配置或系统 Dock 重启后它会回到内建屏，挪回来之前不读原生菜单。
        hiddenDockScreenUUID = nil; updateShadowTarget()
        hiddenDockRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, hasEnteredDock, nativeDock.isActive, nativeDock.shadow == nil, !relocatingHiddenDock,
                  terminationTask == nil, !isEnding else { return }
            CoreDockAutoHide.set(true)
            relocateHiddenDock()
        }
        hiddenDockRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 悬停到某个图标时只刷新它的窗口缓存；最小化窗口不必等 10 秒兜底。
    private func refreshHoveredWindowCaches() {
        guard let store, let id = bar.hoveredItemID else { return }
        let apps: [AppReference]
        if let item = store.configuration.items.first(where: { $0.id == id }), case .app(let app) = item {
            apps = [app]
        } else {
            apps = store.configuration.apps(for: id)
        }
        let now = ProcessInfo.processInfo.systemUptime
        for app in apps where now - (lastHoveredWindowRefresh[app.path] ?? 0) > 2 {
            lastHoveredWindowRefresh[app.path] = now
            AppWindowService.shared.refresh(app)
        }
    }

    private func refreshWindowCaches() {
        if usesNativeHost {
            guard let id = panel.currentGroupID, let group = store.configuration.groups.first(where: { $0.id == id }) else { return }
            AppWindowService.shared.refreshRunningApplications(group.apps)
            return
        }
        let apps = ShelfRunningApplications.shared.regularReferences.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        AppWindowService.shared.refreshRunningApplications(apps)
    }

    /// 期望的系统 Dock 模式：常显时用影子 Dock（系统占位与最小化终点由系统 Dock 承担），自动隐藏时隐藏系统 Dock。
    /// 默认彻底隐藏系统 Dock（经典模式）：影子 Dock 必须让系统 Dock 一直显示再用截屏盖住，
    /// 截屏拿不到窗口阴影、要拦标签、要遮菜单，副作用补不完。需要影子 Dock 时：
    /// `defaults write io.daliang.dockfolders useShadowDock -bool true` 后重启应用（或环境变量 DOCKFOLDERS_SHADOW=1）。
    private var prefersShadowDock: Bool {
        UserDefaults.standard.bool(forKey: "useShadowDock") || ProcessInfo.processInfo.environment["DOCKFOLDERS_SHADOW"] == "1"
    }

    private var wantedShadow: NativeDockCoordinator.ShadowConfiguration? {
        guard let store, prefersShadowDock, !shadowUnavailable, !store.configuration.autoHide, !usesExperimentalMinimization,
              ProcessInfo.processInfo.environment["DOCKFOLDERS_CLASSIC"] != "1",
              CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { return nil }
        return .init(tileSize: Double(store.configuration.options?.iconSize ?? 37), orientation: store.configuration.position.rawValue)
    }

    private func enterNativeMode() throws {
        if let shadow = wantedShadow {
            do {
                try nativeDock.enter(shadow: shadow)
                systemRegion = nil
                shadowDock.onPointerInDock = { [weak self] point in self?.bar.pointerNudged(at: point) }
                shadowDock.start()
                updateShadowTarget()
                log?.record("影子 Dock 已启用：系统 Dock 负责占位与最小化终点，应用栏覆盖显示。")
                return
            } catch {
                shadowUnavailable = true
                log?.record("影子 Dock 启用失败，改用隐藏系统 Dock：\(error.localizedDescription)")
            }
        }
        try nativeDock.enter(suppressNativeMinimization: usesExperimentalMinimization && DockMinimizationController.hasRequiredPermissions)
        guard let regionWatchdog, let store else { return }
        let region = DockSystemRegionController(dataDirectory: store.root, watchdogExecutable: regionWatchdog)
        systemRegion = region
        region.onStateChanged = { [weak self, weak region] in
            guard let self, let region, self.systemRegion === region,
                  self.terminationTask == nil, !self.isEnding else { return }
            self.updateCompatibleWorkArea()
            self.writeRuntimeDiagnostics()
        }
        region.start(areas: bar.visibleDockAreas, preferredDisplayUUID: bar.activeDisplayUUID)
        // 系统 Dock 重启后回到内建屏；藏着时最小化会缩向它所在的屏，挪到应用栏所在屏。
        // 进入经典模式时系统 Dock 刚重启，头一两秒不响应开关与推边（实测 1 秒时约一半失败），等 2.5 秒再挪。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.relocateHiddenDock() }
    }

    /// 经典模式：藏着的系统 Dock 不响应推边换屏（实测推两次不动）。临时关掉自动隐藏（CoreDock 即时开关，
    /// 不重启 Dock）让它露出来，在应用栏所在屏底边露在外面的一段推指针 1.2 秒（推完放回），再恢复隐藏。约 2 秒。
    /// 没挪成就隔 1.5 秒再试，最多 3 次；按着鼠标或指针 1 秒内动过时顺延，免得和用户抢指针。
    /// 推边要压满约一个弹出延迟才换屏（延迟 3600 秒时推不动），所以经典模式延迟只设 1 秒。
    /// 推之前还要放开目标屏的边缘拦截、交还预留区：我们登记在目标屏的预留区会让系统认定 Dock 已在那块屏，
    /// 推边不再换屏（实测登记后推不动、撤掉一推就过去）。推完恢复。
    /// 经典模式下还能改系统 Dock：挪屏、对齐尺寸的回调都有延迟，期间可能已开始退出或换成影子模式。
    /// 退出流程会把自动隐藏和图标尺寸恢复成用户原值，之后再改会让系统 Dock 停在隐藏状态或尺寸不对。
    private var canAdjustHiddenDock: Bool {
        nativeDock.isActive && nativeDock.shadow == nil && terminationTask == nil && !isEnding
    }

    private func relocateHiddenDock(attempt: Int = 1) {
        // 查系统 Dock 在哪块屏要取全系统窗口列表，放到后台线程，取到后回主线程接着判断。
        Task.detached(priority: .userInitiated) { [weak self] in
            let center = ShadowDockGeometry.dockWindowCenter()
            await MainActor.run { [weak self] in self?.relocateHiddenDock(attempt: attempt, dockCenter: center) }
        }
    }

    private func relocateHiddenDock(attempt: Int, dockCenter: CGPoint?) {
        guard hasEnteredDock, canAdjustHiddenDock, !relocatingHiddenDock, let store, let uuid = bar.activeDisplayUUID,
              let target = NSScreen.screens.first(where: { DockDisplayDescriptor.uuid(for: $0) == uuid }),
              let current = ShadowDockGeometry.screen(containing: dockCenter) else { return }
        guard current != target else {
            hiddenDockScreenUUID = uuid; updateShadowTarget()
            alignHiddenDock(); return
        }
        hiddenDockScreenUUID = nil
        guard NSEvent.pressedMouseButtons == 0,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) > 1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.relocateHiddenDock(attempt: attempt) }
            return
        }
        let orientation = store.configuration.position
        guard let point = ShadowDockGeometry.exposedEdgePoint(on: target, orientation: orientation) else {
            log?.record("应用栏所在屏没有露在外面的底边，隐藏的系统 Dock 无法挪过去。")
            return
        }
        let region = systemRegion
        region?.stopAndRestore()
        relocatingHiddenDock = true
        updateShadowTarget()
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            relocatingHiddenDock = false
            updateShadowTarget()
            if let region, systemRegion === region, terminationTask == nil, !isEnding {
                region.start(areas: bar.visibleDockAreas, preferredDisplayUUID: bar.activeDisplayUUID)
            }
        }
        guard CoreDockAutoHide.set(false) else {
            log?.record("找不到系统 Dock 自动隐藏开关，未挪动隐藏的系统 Dock。")
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard canAdjustHiddenDock else { log?.record("已开始退出或换了模式，不再挪动隐藏的系统 Dock。"); finish(); return }
            Task.detached(priority: .userInitiated) { ShadowDockGeometry.push(at: point, orientation: orientation, restorePointer: true, count: 100) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                guard canAdjustHiddenDock else { log?.record("已开始退出或换了模式，不再挪动隐藏的系统 Dock。"); finish(); return }
                CoreDockAutoHide.set(true)
                finish()
                Task.detached(priority: .userInitiated) { [weak self] in
                    let center = ShadowDockGeometry.dockWindowCenter()
                    await MainActor.run { [weak self] in self?.finishHiddenDockRelocation(attempt: attempt, targetUUID: uuid, dockCenter: center) }
                }
            }
        }
    }

    private func finishHiddenDockRelocation(attempt: Int, targetUUID: String, dockCenter: CGPoint?) {
        let moved = ShadowDockGeometry.screen(containing: dockCenter).flatMap { DockDisplayDescriptor.uuid(for: $0) } == targetUUID
        hiddenDockScreenUUID = moved ? targetUUID : nil
        updateShadowTarget()
        if !moved, attempt < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.relocateHiddenDock(attempt: attempt + 1) }
            return
        }
        log?.record(moved ? "隐藏的系统 Dock 已挪到应用栏所在屏（第 \(attempt) 次），最小化会缩向这里。"
                          : "隐藏的系统 Dock 试了 \(attempt) 次仍未挪到应用栏所在屏，最小化会缩向它所在的屏。")
        // 等收起动画走完再对齐，免得露着的系统 Dock 在收起途中跟着变小。
        if moved { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.alignHiddenDock() } }
    }

    /// 插件画出新图标：清掉该 App 与分组的图标缓存，合并到下一轮刷新应用栏与展开的分组。
    private var dockTileRefresh: DispatchWorkItem?
    private func dockTileChanged(_ path: String) {
        DockIconProvider.shared.invalidate(appPath: path)
        dockTileRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshBar() }
        dockTileRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// 决定两个废纸篓位置的布局：应用栏条目（含最小化窗口、文件）、图标尺寸、运行中 App（系统 Dock 里都有）和所在屏。
    private var hiddenDockLayout: String {
        ([bar.activeDisplayUUID ?? "", String(store?.configuration.options?.iconSize ?? 0)] + barItemIDs
            + ShelfRunningApplications.shared.regularReferences.map(\.path).sorted()).joined(separator: "\n")
    }

    /// 应用栏或运行中 App 变化后合并成 1 秒后对齐一次；布局没变（如 10 秒定时刷新）就不再对齐。
    private func scheduleHiddenDockAlignment() {
        guard hasEnteredDock, nativeDock.shadow == nil, hiddenDockLayout != hiddenDockAlignedLayout else { return }
        hiddenDockAlignment?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.alignHiddenDock() }
        hiddenDockAlignment = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// 经典模式：最小化终点是隐藏的系统 Dock 里新窗口格的位置（废纸篓左边）。系统 Dock 装着全部固定项和运行中 App，
    /// 比应用栏宽，终点横向偏出几十点。按两边废纸篓的横向位置等比调整它的图标尺寸（节距 = 尺寸 + 2），让右端对齐应用栏。
    /// 改尺寸会把系统 Dock 弹出来，随即重新开启自动隐藏就不会露出（实测每 20ms 采样始终在屏外）。尺寸只能取整数，误差约 ±7 点。
    /// 只处理底部；系统 Dock 不在应用栏所在屏时不对齐（换屏成功后会再调用）。尺寸退出或崩溃时由恢复会话写回原值。
    private func alignHiddenDock(round: Int = 0) {
        // 用户正在系统设置里拖“大小”滑块（停手不到 1.5 秒）：先不对齐，免得和滑块抢，停手后再对齐。
        if let changed = userTileSizeChangedAt, case let elapsed = ProcessInfo.processInfo.systemUptime - changed, elapsed < 1.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 - elapsed) { [weak self] in self?.alignHiddenDock(round: round) }
            return
        }
        guard hasEnteredDock, nativeDock.shadow == nil, !relocatingHiddenDock, let store, store.configuration.position == .bottom,
              let uuid = bar.activeDisplayUUID,
              let ours = bar.restingRect(for: "system:trash") else { return }
        Task.detached(priority: .utility) { [weak self] in
            let center = ShadowDockGeometry.dockWindowCenter()
            guard let native = ShadowDockGeometry.readNativeDock(), let trash = native.tiles.last else { return }
            await MainActor.run { [weak self] in
                // 系统 Dock 不在应用栏所在屏时不对齐（换屏成功后会再调用）。
                guard let self, !self.relocatingHiddenDock, self.canAdjustHiddenDock,
                      ShadowDockGeometry.screen(containing: center).flatMap({ DockDisplayDescriptor.uuid(for: $0) }) == uuid,
                      let size = CoreDockTileSize.get() else { return }
                self.hiddenDockSummary = String(format: "%@ 尺寸 %.0f 废纸篓 %.1f 应用栏废纸篓 %.1f",
                                                NSStringFromRect(native.frame), size, trash.frame.midX, ours.midX)
                let center = native.frame.midX
                let wanted = ours.midX - center, actual = trash.frame.midX - center
                guard wanted > 20, actual > 20 else { return }
                let layout = self.hiddenDockLayout
                if layout != self.hiddenDockAlignedLayout { self.hiddenDockAlignedLayout = layout; self.hiddenDockErrors = [:] }
                self.hiddenDockErrors[size.rounded()] = actual - wanted
                let next = min(max(((size + 2) * wanted / actual - 2).rounded(), 16), 128)
                guard abs(next - size.rounded()) >= 1 else { return }
                if let known = self.hiddenDockErrors[next], abs(known) >= abs(actual - wanted) { return }
                do { try self.nativeDock.beginManaging("tilesize") } catch {
                    self.log?.record("未调整隐藏系统 Dock 的图标尺寸：\(error.localizedDescription)")
                    return
                }
                self.hiddenTileSizeSet = next
                CoreDockTileSize.set(next)
                CoreDockAutoHide.set(true)
                self.log?.record(String(format: "隐藏的系统 Dock 图标尺寸 %.0f → %.0f，对齐前废纸篓横向差 %.0f 点", size, next, actual - wanted))
                // 布局不完全按比例缩放，量一次再微调，最多 3 轮。
                if round < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.alignHiddenDock(round: round + 1) }
                }
            }
        }
    }

    /// 自动隐藏、图标尺寸或位置变化时切换系统 Dock 模式；每次切换系统 Dock 会重新载入一次。
    private func syncNativeMode() {
        guard hasEnteredDock, !switchingNativeMode, terminationTask == nil, !isEnding, nativeDock.shadow != wantedShadow else { return }
        switchingNativeMode = true
        defer { switchingNativeMode = false }
        shadowDock.stop(); classicEdgeGuard.setZones(edges: [], dock: [])
        _ = systemRegion?.stopAndRestore(); systemRegion = nil
        do {
            try nativeDock.restore()
            try enterNativeMode()
        } catch {
            showError(error)
            quit()
        }
    }

    private func updateShadowTarget() {
        guard let store else { return }
        let mode = store.configuration.options?.displayMode ?? .followPointer
        guard nativeDock.shadow != nil else { updateClassicEdgeGuard(); return }
        // 同时显示时不主动挪动系统 Dock，避免在两屏间来回推指针；补底跟随系统 Dock 所在屏。
        shadowDock.setTarget(displayUUID: mode == .all ? nil : bar.activeDisplayUUID, locked: mode == .primary || mode == .specific)
        shadowDock.setBarVisible(bar.isAnyBarPresented)
    }

    /// 经典模式：系统 Dock 自动隐藏（弹出延迟 1 秒），指针压到任一屏的 Dock 所在边就会把它弹出来或挪过去，
    /// 之后最小化就缩向那块屏。各屏这条边都拦下鼠标移动（实测拦 4 像素即碰不出来），真实位置转交应用栏，
    /// 应用栏的推边换屏和自动隐藏照常。挪动隐藏的系统 Dock 时放开目标屏。
    private func updateClassicEdgeGuard() {
        guard hasEnteredDock, nativeDock.isActive, nativeDock.shadow == nil, let store else {
            classicEdgeGuard.setZones(edges: [], dock: [])
            return
        }
        let target = relocatingHiddenDock
            ? bar.activeDisplayUUID.flatMap { uuid in NSScreen.screens.first { DockDisplayDescriptor.uuid(for: $0) == uuid } } : nil
        classicEdgeGuard.setZones(edges: [], dock: DockEdgeGuard.zones(excluding: target, orientation: store.configuration.position))
    }

    private func deliverClassicEdgePointer() {
        guard let location = classicEdgeGuard.takeDockLocation() else { return }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        bar.pointerNudged(at: CGPoint(x: location.x, y: primaryHeight - location.y))
    }

    private func refreshBar() {
        guard let store, !isEnding else { return }
        // 应用栏要重排，悬浮窗避让的扫描先让一让（见 DockFloatingAvoidance.holdScans）。
        floatingAvoidance.holdScans(for: 0.5)
        if usesNativeHost {
            displayItems = store.configuration.items
            for app in nativeHost?.applicationReferences ?? [] where !displayItems.contains(where: { $0.id == ShelfItem.app(app).id }) {
                displayItems.append(.app(app))
            }
            if let id = panel.currentGroupID {
                if let group = store.configuration.groups.first(where: { $0.id == id }) { panel.refresh(group: group) }
                else { panel.hide() }
            }
            writeRuntimeDiagnostics()
            return
        }
        if hasEnteredDock && !switchingNativeMode && !nativeDock.isActive { quit(); return }
        let configuration = store.configuration
        var items = configuration.items
        let containedApps = configuration.items.flatMap { configuration.apps(for: $0.id) }
        let contained = Set(containedApps.map(\.path))
        // 分组或固定项里放的是启动器时，它拉起的主程序不另占一个图标。
        func launchedByContained(_ app: AppReference) -> Bool { containedApps.contains { $0.launches(app) } }
        let running = ShelfRunningApplications.shared.regularReferences.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        for reference in running {
            guard !contained.contains(reference.path), !launchedByContained(reference),
                  !items.contains(where: { $0.id == ShelfItem.app(reference).id }) else { continue }
            items.append(.app(reference))
        }
        let fixedIDs = Set(configuration.items.map(\.id))
        let runningIDs = Set(items.map(\.id))
        let recentIDs: Set<String>
        let showsRecent = configuration.options?.showRecentApplications != false
        if showsRecent {
            let recent = (configuration.recentApplications ?? []).filter {
                !contained.contains($0.path) && !launchedByContained($0) && !runningIDs.contains(ShelfItem.app($0).id)
                    && !isTransientAppPath($0.path) && FileManager.default.fileExists(atPath: $0.path)
            }.prefix(3)
            recentIDs = Set(recent.map { ShelfItem.app($0).id })
            items.append(contentsOf: recent.map(ShelfItem.app))
        } else { recentIDs = [] }
        displayItems = items
        let appPaths = items.compactMap { item -> String? in if case .app(let app) = item { return app.path }; return nil }
        DockTilePluginService.shared.update(appPaths: appPaths + configuration.groups.flatMap { $0.apps.map(\.path) })
        var display = items.compactMap { item -> DockDisplayItem? in
            switch item {
            case .app(let app):
                return DockDisplayItem(id: item.id, name: app.name, icon: ShelfAppActions.icon(app), isRunning: configuration.options?.showRunningIndicators != false && ShelfAppActions.running(app) != nil, isGroup: false,
                                       section: recentIDs.contains(item.id) ? .recent : (fixedIDs.contains(item.id) || !showsRecent ? .applications : .running), badge: nativeStatuses[app.path]?.badge)
            case .group(let id):
                guard let group = configuration.groups.first(where: { $0.id == id }) else { return nil }
                let badges = group.apps.compactMap { nativeStatuses[$0.path]?.badge }.filter { !$0.isEmpty }
                let numbers = badges.compactMap(Int.init)
                var total = 0
                var overflow = false
                for number in numbers { let sum = total.addingReportingOverflow(number); total = sum.partialValue; overflow = overflow || sum.overflow }
                let badge: String? = badges.isEmpty ? nil : (numbers.count == badges.count && !overflow ? String(total) : "•")
                return DockDisplayItem(id: item.id, name: group.name, icon: ShelfAppActions.groupIcon(group), isRunning: configuration.options?.showRunningIndicators != false && group.apps.contains(where: { ShelfAppActions.running($0) != nil }), isGroup: true, badge: badge, memberCount: group.apps.count)
            }
        }
        minimizedWindows.removeAll()
        if configuration.options?.minimizeToApplication != true {
            for entry in AppWindowService.shared.cachedSnapshots {
                guard ShelfAppActions.running(entry.application)?.processIdentifier == entry.snapshot.processIdentifier else { continue }
                for window in entry.snapshot.windows where window.isMinimized {
                    let id = "system:window:" + window.id
                    minimizedWindows[id] = (entry.application, window)
                    display.append(DockDisplayItem(id: id, name: window.title, icon: DockIconProvider.shared.minimizedWindowIcon(for: entry.application), isRunning: false, isGroup: false, section: .files, acceptsFileDrops: false))
                }
            }
        }
        for file in configuration.files ?? [] {
            display.append(DockDisplayItem(id: file.id, name: file.name, icon: NSWorkspace.shared.icon(forFile: file.path), isRunning: false, isGroup: false, section: .files, acceptsFileDrops: file.isDirectory))
        }
        // 废纸篓状态由后台每 0.5 秒更新；刷新应用栏不再同步读偏好。
        let trash = NSImage(named: lastTrashIsEmpty == true ? NSImage.trashEmptyName : NSImage.trashFullName) ?? NSImage(systemSymbolName: "trash", accessibilityDescription: "废纸篓") ?? NSImage()
        display.append(DockDisplayItem(id: "system:trash", name: "废纸篓", icon: trash, isRunning: false, isGroup: false, section: .files))
        var appearance = DockBarAppearance.nativeDefaults
        if let options = configuration.options {
            appearance.iconSize = CGFloat(options.iconSize)
            appearance.maxIconSize = CGFloat(options.maximumIconSize)
            appearance.magnification = options.magnification
            appearance.showRunningIndicators = options.showRunningIndicators
            appearance.animateLaunching = options.animateLaunching
        }
        panel.animatesLaunch = appearance.animateLaunching
        barItemIDs = display.map(\.id)
        bar.show(items: display, position: configuration.position, autoHide: configuration.autoHide, appearance: appearance,
                 displayMode: configuration.options?.displayMode ?? .followPointer,
                 displayUUID: configuration.options?.displayUUID)
        syncNativeMode()
        scheduleHiddenDockAlignment()
        shadowDock.refreshNow()
        updateWorkArea()
        if let id = panel.currentGroupID {
            if let group = configuration.groups.first(where: { $0.id == id }) { panel.refresh(group: group) } else { panel.hide() }
            if let anchor = bar.anchorRect(for: ShelfItem.group(id).id) { panel.updateAnchor(anchor) }
        }
        writeRuntimeDiagnostics()
    }

    /// 访达每次改变废纸篓状态都会写系统 Dock 偏好 trash-full，原生 Dock 按它切换图标；没有这一项时直接读废纸篓目录
    /// （需要完全磁盘访问权限），都读不到时为 nil。
    private var trashIsEmpty: Bool? { Self.readTrashIsEmpty() }

    nonisolated static func readTrashIsEmpty() -> Bool? {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        if let full = CFPreferencesCopyAppValue("trash-full" as CFString, "com.apple.dock" as CFString) as? Bool { return !full }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.isEmpty
    }

    private func item(_ id: String) -> ShelfItem? {
        if let found = displayItems.first(where: { $0.id == id }) { return found }
        if usesNativeHost, id.hasPrefix("app:"), let app = AppReference(url: URL(fileURLWithPath: String(id.dropFirst(4)))) { return .app(app) }
        return nil
    }

    private func updateWorkArea() {
        let areas = bar.visibleDockAreas
        _ = systemRegion?.update(areas: areas, preferredDisplayUUID: bar.activeDisplayUUID)
        updateShadowTarget()
        updateCompatibleWorkArea()
    }

    /// 状态回调不反向请求系统区域，避免两个更新入口互相触发。
    /// 已登记真实区域的屏幕仍需照顾缓存未刷新的旧应用；几何规则跳过已避让的窗口。
    private func updateCompatibleWorkArea() {
        let areas = bar.visibleDockAreas
        workArea.update(areas)
        floatingAvoidance.update(zones: DockWorkAreaService.zones(for: areas))
    }

    /// 诊断只保留几何和计数，不保存窗口内容、截图或用户文档标题。
    private func writeRuntimeDiagnostics() {
        guard let store else { return }
        // 明确请求诊断时（会先清掉上次的结果）才实时核对系统预留区，平时按登记结果写。
        let verifyRegion = lastRuntimeDiagnostics == nil
        func rectangle(_ rect: CGRect) -> [String: Double] {
            ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        if usesNativeHost {
            let value: [String: Any] = ["version": "0.6.0", "host": "native-dock", "customShelf": false,
                "windowAdjustment": false, "screenCapture": false,
                "groupCount": store.configuration.groups.count,
                "orientation": nativeHost?.orientation.rawValue ?? "bottom",
                "screens": NSScreen.screens.map { ["frame": rectangle($0.frame), "visibleFrame": rectangle($0.visibleFrame)] }]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), data != lastRuntimeDiagnostics else { return }
            let path = store.root.appendingPathComponent("Diagnostics/0.5-runtime.json")
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: path, options: .atomic)
            lastRuntimeDiagnostics = data
            return
        }
        let value: [String: Any] = [
            "version": "0.8.0",
            "host": "custom-shelf",
            "displayMode": (store.configuration.options?.displayMode ?? .followPointer).rawValue,
            "displayUUID": store.configuration.options?.displayUUID as Any? ?? NSNull(),
            "reservedAreas": bar.visibleDockAreas.map { area in
                ["displayUUID": area.displayUUID, "screen": rectangle(area.screenFrame), "reserved": rectangle(area.reservedFrame), "position": area.position.rawValue] as [String: Any]
            },
            "windowSpaceEnabled": true,
            "systemReservedArea": (verifyRegion ? systemRegion?.verifyApplied() : systemRegion?.isApplied) == true,
            "systemReservedDisplayUUID": systemRegion?.activeDisplayUUID as Any? ?? NSNull(),
            "systemReservedAreaError": systemRegion?.lastError as Any? ?? NSNull(),
            "fullscreenDisplayIDs": fullscreenTracker.activeDisplayIDs,
            "frameTiming": bar.frameTimingSummaries,
            "barItems": bar.itemFramesForDiagnostics,
            "windowSpace": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(workArea.lastReport))) ?? [:],
            "minimization": minimization.diagnosticSummary,
            "nativeMode": nativeDock?.shadow != nil ? "shadow" : "hidden",
            "shadowDock": shadowDock.summary,
            "classicEdgeGuard": classicEdgeGuard.summary,
            "dockTilePlugins": DockTilePluginService.shared.summary,
            "windowPreview": WindowPreviewController.shared.summary,
            "floatingAvoidance": { let r = floatingAvoidance.summary; return ["moved": r.moved, "released": r.released, "lastApp": r.lastApp] }(),
            // 经典模式下系统 Dock 藏着，用它的辅助功能外框判断停在哪块屏（最小化会缩向那里）。
            "hiddenSystemDock": hiddenDockSummary
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), data != lastRuntimeDiagnostics else { return }
        let directory = store.root.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("0.8-runtime.json"), options: .atomic)
            lastRuntimeDiagnostics = data
        } catch { log?.record("运行诊断保存失败：\(error.localizedDescription)") }
    }

    /// 临时构建产物不应进入最近应用，也不应出现在应用栏。
    private var referencedApplications: [AppReference] {
        let configuration = store.configuration
        let pinned = configuration.items.compactMap { item -> AppReference? in if case .app(let app) = item { return app }; return nil }
        return pinned + configuration.groups.flatMap(\.apps) + (configuration.recentApplications ?? [])
    }

    private func installedApplicationsChanged(_ paths: [String]) {
        let apps = Set((referencedApplications + removedApplications.values.map(\.app)).map(\.path))
        let paths = FolderLayout.relevantApplicationChanges(paths, applications: apps,
                                                            extraFolders: ["/Applications", NSHomeDirectory() + "/Applications"])
        guard !paths.isEmpty else { return }
        // 同一位置重装、更新后图标会变：丢掉这些应用的图标缓存，核对时重新取。
        for app in apps where paths.contains(where: { $0 == app || $0.hasPrefix(app + "/") }) {
            DockIconProvider.shared.invalidate(appPath: app)
            DockTilePluginService.shared.forget(appPath: app)
        }
        scheduleApplicationCheck(after: 1)
    }

    private func scheduleApplicationCheck(after delay: TimeInterval) {
        applicationCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkInstalledApplications() }
        applicationCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 应用栏、分组与最近使用里的应用：卸载了就移除，移动或重装后换成现在的位置和信息。
    private func checkInstalledApplications() {
        guard let store, !isEnding else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var next = store.configuration
        // 先把最近自动移除、现在又装回来的应用放回原处。
        var restored: [String] = []
        for (path, entry) in removedApplications {
            guard now - entry.removedAt < Self.removedApplicationMemory else { removedApplications[path] = nil; continue }
            let current = FileManager.default.fileExists(atPath: entry.app.path)
                ? AppReference(url: entry.app.appURL) ?? entry.app : installedCopy(of: entry.app)
            guard let current else { continue }
            removedApplications[path] = nil
            if next.restore(current, at: entry.placement) {
                if !restored.contains(current.name) { restored.append(current.name) }
                log.record("应用重新装好，放回原位：\(current.path)")
            }
        }
        let before = next
        let changes = next.updateApplications { applicationUpdate(for: $0, now: now) }
        for (old, change) in changes where change == .remove {
            if let placement = before.placement(of: old) { removedApplications[old.path] = (old, placement, now) }
        }
        let folders = (referencedApplications + removedApplications.values.map(\.app)).map { $0.appURL.deletingLastPathComponent().path }
        installedApplications.watch(Set(folders + ["/Applications", NSHomeDirectory() + "/Applications"]))
        // 按最近一个到期的宽限再核对，不在移除宽限内每 5 秒重读一遍。
        if let due = missingApplications.values.map({ since -> TimeInterval in
            let elapsed = now - since
            return (elapsed < Self.missingApplicationGrace ? Self.missingApplicationGrace : Self.missingApplicationRemoval) - elapsed
        }).min() { scheduleApplicationCheck(after: max(1, due)) }
        guard !changes.isEmpty || !restored.isEmpty else { refreshBar(); return }
        var removed: [String] = [], replaced: [String] = []
        for (old, change) in changes.sorted(by: { $0.key.path < $1.key.path }) {
            switch change {
            case .remove:
                if !removed.contains(old.name) { removed.append(old.name) }
                log.record("应用已卸载，自动移除：\(old.path)")
            case .replace(let app):
                if !replaced.contains(app.name) { replaced.append(app.name) }
                log.record("应用已移动或重装，自动替换：\(old.path)（\(old.bundleIdentifier ?? "无包名")）→ \(app.path)（\(app.bundleIdentifier ?? "无包名")）")
            case .keep: break
            }
        }
        var message: [String] = []
        if !removed.isEmpty { message.append("已移除卸载的应用：\(removed.joined(separator: "、"))") }
        if !replaced.isEmpty { message.append("已更新重装或移动的应用：\(replaced.joined(separator: "、"))") }
        if !restored.isEmpty { message.append("已把重新装好的应用放回原位：\(restored.joined(separator: "、"))") }
        apply(next, message: message.joined(separator: "；") + "。")
    }

    private func applicationUpdate(for app: AppReference, now: TimeInterval) -> AppReferenceUpdate {
        if app.path == finderPath || isTransientAppPath(app.path) { return .keep }
        let files = FileManager.default
        if files.fileExists(atPath: app.path) {
            missingApplications[app.path] = nil
            // 同一位置装成了包名不同的应用：位置不动，换成现在的名称和包名。直接读 Info.plist，Bundle 会缓存旧内容。
            guard let info = CFBundleCopyInfoDictionaryInDirectory(app.appURL as CFURL) as? [String: Any],
                  let bundleID = info["CFBundleIdentifier"] as? String, bundleID != app.bundleIdentifier else { return .keep }
            let name = (files.displayName(atPath: app.path) as NSString).deletingPathExtension
            return .replace(AppReference(path: app.path, name: name, bundleIdentifier: bundleID))
        }
        let since = missingApplications[app.path] ?? now
        missingApplications[app.path] = since
        guard now - since >= Self.missingApplicationGrace - 0.1 else { return .keep }
        if let moved = installedCopy(of: app) { missingApplications[app.path] = nil; return .replace(moved) }
        guard now - since >= Self.missingApplicationRemoval - 0.1 else { return .keep }
        missingApplications[app.path] = nil
        // 所在文件夹也不在（外接磁盘没接上、文件夹改了名）时不当作卸载，留着等它回来。
        return files.fileExists(atPath: app.appURL.deletingLastPathComponent().path) ? .remove : .keep
    }

    /// 按包名找装到别处的同一应用：直接扫原文件夹和各“应用程序”文件夹（刚装好的应用未必已被系统登记），
    /// 不认废纸篓、安装镜像、开发构建产物等其他位置。
    private func installedCopy(of app: AppReference) -> AppReference? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        var folders: [String] = []
        for folder in [app.appURL.deletingLastPathComponent().path, "/Applications", NSHomeDirectory() + "/Applications"]
        where !folders.contains(folder) { folders.append(folder) }
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "app" && url.path != app.path {
                let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as? [String: Any]
                if info?["CFBundleIdentifier"] as? String == bundleID, let found = AppReference(url: url) { return found }
            }
        }
        return nil
    }

    /// 像原生 Dock 一样，退出时还有 Dock 图标的 App 才记进“最近使用”。原来在启动时记，
    /// 启动后立即藏起 Dock 图标的 App（如 Clash Verge）也被记进去，退出后一直留在栏上。
    private func rememberRecentApplication(_ app: AppReference) {
        guard let store, !isEnding, terminationTask == nil, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !isTransientAppPath(app.path) else { return }
        var next = store.configuration
        var recent = next.recentApplications ?? []
        recent.removeAll { $0.path == app.path }; recent.insert(app, at: 0)
        next.recentApplications = Array(recent.prefix(12))
        try? store.save(next, recordUndo: false)
    }

    /// 正在运行却没有 Dock 图标的 App 从“最近使用”里去掉，包括改前误记的。
    private func pruneRecentApplications() {
        guard let store, let recent = store.configuration.recentApplications else { return }
        let kept = recent.filter { !ShelfRunningApplications.shared.runsWithoutDockIcon($0.path) }
        guard kept.count != recent.count else { return }
        var next = store.configuration
        next.recentApplications = kept
        try? store.save(next, recordUndo: false)
    }

    private func isTransientAppPath(_ path: String) -> Bool {
        path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }

    private func minimizationTarget(path: String, windowID: String?, sourcePoint: CGPoint) -> CGRect? {
        guard let store else { return nil }
        minimizationGeneration += 1
        let generation = minimizationGeneration
        bar.setInteractionHold("window-animation", active: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, self.minimizationGeneration == generation else { return }
            self.bar.setInteractionHold("window-animation", active: false)
        }
        if let windowID, let rect = bar.anchorRect(for: "system:window:" + windowID, nearAppKitPoint: sourcePoint) { return rect }
        if let group = store.configuration.groups.first(where: { $0.apps.contains(where: { $0.path == path }) }),
           let rect = bar.anchorRect(for: ShelfItem.group(group.id).id, nearAppKitPoint: sourcePoint) { return rect }
        return bar.anchorRect(for: "app:" + path, nearAppKitPoint: sourcePoint)
    }

    private func openItem(_ id: String, point: CGPoint) {
        if !usesNativeHost { updateWorkArea() }
        if usesNativeHost, case .group(let groupID) = item(id), let group = store.configuration.groups.first(where: { $0.id == groupID }) {
            showNativeGroup(group)
            return
        }
        if let entry = minimizedWindows[id] {
            panel.hide(); filesPanel.hide(); AppWindowService.shared.select(entry.window, in: entry.application); return
        }
        if id == "system:trash" {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")); return
        }
        if id == "system:downloads" {
            openFile(ShelfFile(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")), point: point); return
        }
        if let file = store.configuration.files?.first(where: { $0.id == id }) { openFile(file, point: point); return }
        guard let item = item(id) else { return }
        switch item {
        case .app(let app): panel.hide(); filesPanel.hide(); ShelfAppActions.open(app, modifiers: NSEvent.modifierFlags); log.record("打开或切换：\(app.name)")
        case .group(let groupID):
            guard let group = store.configuration.groups.first(where: { $0.id == groupID }) else { return }
            bar.setInteractionHold("panel-transition", active: true)
            defer { bar.setInteractionHold("panel-transition", active: false) }
            filesPanel.hide()
            // 不经应用栏单击的展开（链接、管理窗口）原先不锁布局，面板对准的是动画中的图标，条目增减后要等下次刷新才跟上。
            // 再次点击已展开的分组是收起（面板自己记“收起分组”），不记“展开”。
            let collapsing = panel.currentGroupID == groupID
            if !collapsing { bar.retainGroupAnchor(id) }
            if let rect = bar.anchorRect(for: id) { panel.show(group: group, anchor: rect, position: store.configuration.position) }
            else { panel.show(group: group, near: point, position: store.configuration.position) }
            if !collapsing { log.record("展开分组：\(group.name)") }
        }
    }

    private func openFile(_ file: ShelfFile, point: CGPoint) {
        bar.setInteractionHold("panel-transition", active: true)
        defer { bar.setInteractionHold("panel-transition", active: false) }
        panel.hide()
        if NSEvent.modifierFlags.contains(.command) { NSWorkspace.shared.activateFileViewerSelecting([file.url]); return }
        guard file.isDirectory else { filesPanel.hide(); NSWorkspace.shared.open(file.url); return }
        let height = NSScreen.screens.first?.frame.height ?? 0
        let anchor = bar.anchorRect(for: file.id) ?? CGRect(x: point.x - 18, y: height - point.y - 18, width: 36, height: 36)
        filesPanel.show(directory: file.url, anchor: anchor, position: store.configuration.position)
    }

    private func removeItem(_ id: String) {
        var next = store.configuration
        var message = "已从应用栏移除；文件和应用仍保留。"
        if next.files?.contains(where: { $0.id == id }) == true {
            next.files?.removeAll { $0.id == id }
        } else if let item = item(id) {
            if case .app(let app) = item, app.path == finderPath { return }
            if case .group(let groupID) = item, let group = next.groups.first(where: { $0.id == groupID }) {
                // 分组只存在于本应用的配置里，移除即删掉分组名和成员归组，不像文件夹那样还留在磁盘上，所以先确认。
                guard confirmGroupRemoval(group) else { log.record("移除分组：已取消"); refreshBar(); return }
                next.groups.removeAll { $0.id == groupID }; panel.hide()
                message = "分组“\(group.name)”已移除；组内 App 未卸载，可用“撤销布局更改”恢复。"
            }
            next.items.removeAll { $0.id == id }
        } else { return }
        apply(next, message: message)
    }

    /// 与管理窗口的“解散分组”一致：回车是“取消”。
    private func confirmGroupRemoval(_ group: AppGroup) -> Bool {
        let alert = NSAlert()
        alert.messageText = "移除分组“\(group.name)”？"
        alert.informativeText = "分组和其中 \(group.apps.count) 个 App 的归组会被删除，App 本身不会被卸载。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移除分组").hasDestructiveAction = true
        return runConfirmation(alert, cancel: .alertFirstButtonReturn) == .alertSecondButtonReturn
    }

    /// 弹出确认框并能用回车、Esc 操作。本应用没有 Dock 图标，点应用栏不会激活它；NSApp.activate() 在 macOS 14 以后
    /// 只是请求，前台 App 不让出就不生效（10-23 实测确认框弹出时本应用不在前台，回车和 Esc 都落到了别的 App）。
    /// 与菜单浮层一样把确认框设成不激活也能拿键盘的面板，Esc 一律当作取消。
    private func runConfirmation(_ alert: NSAlert, cancel: NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        alert.layout()
        let window = alert.window
        if let panel = window as? NSPanel { panel.styleMask.insert(.nonactivatingPanel); panel.becomesKeyOnlyIfNeeded = false }
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.keyCode == 53, let window, event.window === window else { return false }
                NSApp.stopModal(withCode: cancel)
                return true
            }
            return handled ? nil : event
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        return alert.runModal()
    }

    private func promote(_ id: String, in configuration: inout ShelfConfiguration) {
        if !configuration.items.contains(where: { $0.id == id }), let item = item(id) { configuration.items.append(item) }
    }

    private func canGroup(_ item: ShelfItem) -> Bool {
        if case .app(let app) = item { return app.path != finderPath }
        return true
    }

    private func merge(_ source: String, into target: String) {
        guard let sourceItem = item(source), let targetItem = item(target), canGroup(sourceItem), canGroup(targetItem) else { return }
        var next = store.configuration
        promote(source, in: &next)
        promote(target, in: &next)
        guard let groupID = next.merge(sourceID: source, targetID: target) else { return }
        if usesNativeHost, next == store.configuration,
           let existing = next.groups.first(where: { $0.id == groupID }) {
            setStatus("这两个入口已在“\(existing.name)”中。")
            showNativeGroup(existing)
            return
        }
        // 拖进已展开的分组面板：面板原地刷新出新成员，不收起再展开。
        if case .group(let openID) = targetItem, panel.currentGroupID == openID {
            // 放进面板让出的空位，而不是排到最后。
            if let index = panel.takeIncomingIndex(), case .app(let app) = sourceItem,
               let groupIndex = next.groups.firstIndex(where: { $0.id == openID }),
               let current = next.groups[groupIndex].apps.firstIndex(where: { $0.path == app.path }) {
                let member = next.groups[groupIndex].apps.remove(at: current)
                next.groups[groupIndex].apps.insert(member, at: min(index, next.groups[groupIndex].apps.count))
            }
            if apply(next, message: "已加入分组。") { log.record("拖入展开的分组：\(source) → group:\(openID.uuidString)") }
            return
        }
        panel.hide()
        if apply(next, message: "已合并为一个分组。单击分组展开，右键可改名、解散。") {
            log.record("拖叠合并：\(source) + \(target) → group:\(groupID.uuidString)")
            if usesNativeHost, let created = store.configuration.groups.first(where: { $0.id == groupID }) {
                showNativeGroup(created)
            } else if !usesNativeHost {
                openItem(ShelfItem.group(groupID).id, point: .zero)
            }
        }
    }

    private func reorder(_ id: String, insertion: Int) {
        if let fileIndex = store.configuration.files?.firstIndex(where: { $0.id == id }) {
            var next = store.configuration
            let file = next.files!.remove(at: fileIndex)
            let fileIDs = Set((store.configuration.files ?? []).map(\.id))
            let before = displayItemIDs().prefix(max(0, insertion)).filter { fileIDs.contains($0) && $0 != id }.count
            next.files!.insert(file, at: min(before, next.files!.count))
            apply(next, message: "文件入口顺序已保存。")
            return
        }
        guard let moved = item(id) else { return }
        if case .app(let app) = moved, app.path == finderPath { return }
        var next = store.configuration
        promote(id, in: &next)
        let before = displayItems.prefix(max(0, min(insertion, displayItems.count)))
        let fixedIDs = Set(next.items.map(\.id))
        let adjusted = before.filter { fixedIDs.contains($0.id) }.count
        next.reorder(id: id, insertionIndex: max(1, adjusted))
        apply(next, message: "应用栏顺序已保存。")
    }

    private func displayItemIDs() -> [String] { barItemIDs }

    private func handleDrop(_ urls: [URL], target: String?, applicationReference: Bool = false, copyFiles: Bool = false, insertion: Int? = nil) {
        guard !urls.isEmpty else { return }
        if applicationReference {
            if target == "system:trash" || target?.hasPrefix("file:") == true { return }
            addApplications(urls, target: target, insertion: insertion)
            return
        }
        if target == "system:trash" {
            NSWorkspace.shared.recycle(urls) { [weak self] _, error in
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    if let message { self?.showError(DockFoldersError.message(message)) }
                    self?.refreshBar()
                }
            }
            return
        }
        if let target, let folder = store.configuration.files?.first(where: { $0.id == target && $0.isDirectory }) {
            let copy = copyFiles
            Task {
                let failures: [String] = await Task.detached(priority: .userInitiated) {
                    urls.compactMap { url in
                        let destination = folder.url.appendingPathComponent(url.lastPathComponent)
                        guard destination.standardizedFileURL != url.standardizedFileURL else { return nil }
                        do {
                            if copy { try FileManager.default.copyItem(at: url, to: destination) }
                            else { try FileManager.default.moveItem(at: url, to: destination) }
                            return nil
                        } catch { return "\(url.lastPathComponent)：\(error.localizedDescription)" }
                    }
                }.value
                if !failures.isEmpty { showError(DockFoldersError.message(failures.joined(separator: "\n"))) }
                else { setStatus(copy ? "文件已复制到文件夹。" : "文件已移到文件夹。") }
                refreshBar()
            }
            return
        }
        let apps = urls.compactMap(AppReference.init(url:))
        if !apps.isEmpty { addApplications(apps.map(\.appURL), target: target, insertion: insertion) }
        let documents = urls.filter { AppReference(url: $0) == nil }
        guard !documents.isEmpty else { return }
        if let target, case .app(let app) = item(target) { ShelfAppActions.openFiles(documents, with: app); return }
        if let target, case .group = item(target) {
            openItem(target, point: .zero)
            setStatus("请将文件拖到分组内要使用的应用图标上。")
            return
        }
        var next = store.configuration
        var files = next.files ?? []
        for url in documents {
            let file = ShelfFile(url: url)
            if !files.contains(where: { $0.id == file.id }) { files.append(file) }
        }
        next.files = files
        apply(next, message: "文件或文件夹入口已添加。")
    }

    /// `insertion`：应用栏让出空位的位置（显示顺序，固定项在最前，与配置顺序一致）；nil 放到末尾。
    private func addApplications(_ urls: [URL], target: String?, insertion: Int? = nil) {
        let apps = urls.compactMap(AppReference.init(url:)).filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        guard !apps.isEmpty else { return }
        var next = store.configuration
        if let target, let targetItem = item(target), canGroup(targetItem) {
            promote(target, in: &next)
            var targetID = target
            for app in apps where app.path != finderPath {
                let appID = ShelfItem.app(app).id
                if appID == targetID || next.apps(for: targetID).contains(where: { $0.path == app.path }) { continue }
                next.groups = next.groups.map { old in
                    var old = old; old.apps.removeAll { $0.path == app.path }; return old
                }
                if !next.items.contains(where: { $0.id == appID }) { next.items.append(.app(app)) }
                if let groupID = next.merge(sourceID: appID, targetID: targetID) { targetID = ShelfItem.group(groupID).id }
            }
        } else {
            let movedPaths = Set(apps.map(\.path))
            next.groups = next.groups.map { group in var group = group; group.apps.removeAll { movedPaths.contains($0.path) }; return group }
            var index = insertion.map { min(max(0, $0), next.items.count) }
            for app in apps where !next.items.contains(.app(app)) {
                if let current = index { next.items.insert(.app(app), at: current); index = current + 1 }
                else { next.items.append(.app(app)) }
            }
        }
        apply(next, message: "已添加应用。")
    }

    private func updateGroup(_ group: AppGroup) {
        var groups = store.configuration.groups
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        updateGroups(groups)
    }

    private func updateGroups(_ groups: [AppGroup]) {
        var next = store.configuration
        let oldMembers = next.groups.flatMap(\.apps)
        let changedIDs = groups.filter { group in
            next.groups.first(where: { $0.id == group.id })?.apps != group.apps
        }.map(\.id)
        let claimed = Set(groups.filter { changedIDs.contains($0.id) }.flatMap(\.apps).map(\.path))
        next.groups = groups.map { group in
            guard !changedIDs.contains(group.id) else { return group }
            var group = group
            group.apps.removeAll { claimed.contains($0.path) }
            return group
        }
        let newMembers = Set(groups.flatMap(\.apps).map(\.path))
        for app in oldMembers where !newMembers.contains(app.path) && !next.items.contains(.app(app)) { next.items.append(.app(app)) }
        apply(next, message: "分组编辑已保存。")
    }

    private func dissolveGroup(_ id: UUID) {
        var next = store.configuration
        next.dissolve(id)
        panel.hide()
        apply(next, message: "分组已解散，成员已恢复为单独入口。")
    }

    @discardableResult
    private func apply(_ configuration: ShelfConfiguration, message: String) -> Bool {
        let previous = store.configuration
        do {
            if usesNativeHost { try nativeHost?.updateGroups(from: previous.groups, to: configuration.groups) }
            try store.save(configuration)
            if usesNativeHost { entryRuntime?.synchronize(groups: configuration.groups) }
            setStatus(message)
            refreshBar()
            return true
        } catch {
            if usesNativeHost { try? nativeHost?.updateGroups(from: configuration.groups, to: previous.groups) }
            showError(error)
            return false
        }
    }

    private func makeMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DockApex")
        statusItem.button?.toolTip = "DockApex"
        statusItem.menu = settingsMenu()
        let main = NSMenu()
        let root = NSMenuItem()
        root.submenu = settingsMenu()
        main.addItem(root)
        NSApp.mainMenu = main
    }

    private func settingsMenu() -> NSMenu {
        if usesNativeHost { return nativeSettingsMenu() }
        let menu = NSMenu()
        menu.title = "DockApex 设置"
        menu.delegate = self
        menu.addItem(ShelfMenuItem("管理分组") { [weak self] in self?.showManager() })
        let undo = ShelfMenuItem("撤销布局更改", key: "z") { [weak self] in
            guard let self else { return }
            do { try self.store.undo(); self.panel.hide(); self.setStatus("已撤销布局更改。"); self.refreshBar() }
            catch { self.showError(error) }
        }
        undo.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(undo)
        menu.addItem(.separator())
        let position = NSMenuItem(title: "位置", action: nil, keyEquivalent: "")
        let positions = NSMenu()
        for (value, title) in [(DockPosition.bottom, "底部"), (.left, "左侧"), (.right, "右侧")] {
            let choice = ShelfMenuItem(title) { [weak self] in
                guard let self else { return }; var next = self.store.configuration; next.position = value
                self.panel.hide(); self.apply(next, message: "应用栏位置已更新。")
            }
            choice.state = store?.configuration.position == value ? .on : .off
            positions.addItem(choice)
        }
        position.submenu = positions
        menu.addItem(position)
        let display = NSMenuItem(title: "显示器", action: nil, keyEquivalent: "")
        display.identifier = NSUserInterfaceItemIdentifier("display-selection")
        let displays = NSMenu()
        let selectedMode = store?.configuration.options?.displayMode ?? .followPointer
        let selectedUUID = store?.configuration.options?.displayUUID
        for (mode, title) in [(DockDisplayMode.primary, "主显示器"), (.all, "所有显示器"), (.followPointer, "跟随指针")] {
            let choice = ShelfMenuItem(title) { [weak self] in self?.selectDisplay(mode: mode, uuid: nil) }
            choice.identifier = NSUserInterfaceItemIdentifier("display-mode:" + mode.rawValue)
            choice.state = selectedMode == mode ? .on : .off
            displays.addItem(choice)
        }
        displays.addItem(.separator())
        let connected = DockDisplayCoordinator.availableDisplays
        for screen in connected {
            let title = screen.name + (screen.isPrimary ? "（主显示器）" : "")
            let choice = ShelfMenuItem(title) { [weak self] in self?.selectDisplay(mode: .specific, uuid: screen.uuid) }
            choice.identifier = NSUserInterfaceItemIdentifier("display-uuid:" + screen.uuid)
            choice.state = selectedMode == .specific && selectedUUID == screen.uuid ? .on : .off
            displays.addItem(choice)
        }
        if selectedMode == .specific, let selectedUUID, !connected.contains(where: { $0.uuid == selectedUUID }) {
            let disconnected = NSMenuItem(title: "所选显示器未连接", action: nil, keyEquivalent: "")
            disconnected.isEnabled = false; disconnected.state = .on
            displays.addItem(disconnected)
        }
        display.submenu = displays
        menu.addItem(display)
        let hiding = ShelfMenuItem("自动隐藏") { [weak self] in
            guard let self else { return }; var next = self.store.configuration; next.autoHide.toggle()
            self.apply(next, message: next.autoHide ? "应用栏已自动隐藏，移到屏幕边缘唤出。" : "应用栏已始终显示。")
        }
        hiding.state = store?.configuration.autoHide == true ? .on : .off
        menu.addItem(hiding)
        // 对应系统设置“在程序坞中显示建议 App 和最近使用的 App”：关掉后没固定的 App 退出即从应用栏消失。
        let recents = ShelfMenuItem("显示最近使用的 App") { [weak self] in
            guard let self else { return }; var next = self.store.configuration; var options = next.options ?? self.nativeOptions()
            options.showRecentApplications.toggle(); next.options = options
            self.apply(next, message: options.showRecentApplications ? "没固定的 App 退出后会留在“最近使用”里。" : "没固定的 App 退出后不再留在应用栏。")
        }
        recents.state = store?.configuration.options?.showRecentApplications != false ? .on : .off
        menu.addItem(recents)
        // 与系统设置里程序坞的“大小”“放大”滑块对应，拖动时应用栏实时变（10-25 用户要求）。“悬停放大”拖到最左为关。
        // 名称按用户要求写明各管什么：一个是 Dock 平时多大，一个是指针停上去时图标放大到多大。
        let current = store?.configuration.options ?? nativeOptions()
        let sizeItem = NSMenuItem()
        sizeItem.identifier = NSUserInterfaceItemIdentifier("size-slider")
        sizeItem.view = ShelfMenuSlider(title: "Dock 大小", value: current.iconSize, range: 16...128) { [weak self, weak sizeItem] value, finished in
            self?.sizeSliderChanged(value.rounded(), finished: finished, in: sizeItem?.menu)
        }
        menu.addItem(sizeItem)
        let magnificationItem = NSMenuItem()
        magnificationItem.identifier = NSUserInterfaceItemIdentifier("magnification-slider")
        magnificationItem.view = ShelfMenuSlider(title: "悬停放大", value: current.magnification ? current.maximumIconSize : current.iconSize,
                                                 range: current.iconSize...128) { [weak self] value, finished in
            self?.magnificationSliderChanged(value.rounded(), finished: finished)
        }
        menu.addItem(magnificationItem)
        let login = ShelfMenuItem("登录时打开") { [weak self] in
            do { try LoginItemService.toggle(); self?.log.record("登录时打开：\(LoginItemService.statusText)") }
            catch { self?.showError(error) }
        }
        login.state = LoginItemService.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("关于 DockApex") { [weak self] in self?.showAbout() })
        menu.addItem(ShelfMenuItem("退出", key: "q") { [weak self] in self?.quit() })
        return menu
    }

    private func nativeSettingsMenu() -> NSMenu {
        let menu = NSMenu(title: "DockApex 设置")
        menu.delegate = self
        menu.addItem(ShelfMenuItem("管理分组…") { [weak self] in self?.showManager() })
        let undo = ShelfMenuItem("撤销上次分组操作", key: "z") { [weak self] in
            guard let self else { return }
            let before = self.store.configuration
            do {
                try self.store.undo()
                try self.nativeHost?.updateGroups(from: before.groups, to: self.store.configuration.groups)
                self.entryRuntime?.synchronize(groups: self.store.configuration.groups)
                self.panel.hide()
                self.refreshBar()
                self.setStatus("已撤销上次分组操作。")
            } catch {
                try? self.store.save(before, recordUndo: false)
                self.showError(error)
            }
        }
        undo.keyEquivalentModifierMask = [.command, .option]
        undo.isEnabled = store?.previous != nil
        menu.addItem(undo)
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("系统 Dock 设置…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
        })
        menu.addItem(ShelfMenuItem("恢复原始固定应用并退出") { [weak self] in
            self?.restoresNativeLayoutOnQuit = true
            self?.quit()
        })
        menu.addItem(ShelfMenuItem("退出分组工具", key: "q") { [weak self] in self?.quit() })
        return menu
    }

    private func showNativeGroup(_ group: AppGroup) {
        nativeGroupPresentationGeneration += 1
        let token = nativeGroupPresentationGeneration
        if panel.currentGroupID == group.id {
            panel.hide(restoreFocus: true)
            return
        }
        let cached = nativeHost?.entryRect(groupID: group.id)
        Task { @MainActor [weak self] in
            guard let self, let host = self.nativeHost else { return }
            let fresh = await host.refreshEntryRect(groupID: group.id)
            guard !self.isEnding, token == self.nativeGroupPresentationGeneration,
                  let current = self.store.configuration.groups.first(where: { $0.id == group.id }) else { return }
            guard let anchor = fresh ?? cached else {
                self.setStatus("请先将分组入口保留在系统 Dock 中，再打开分组。")
                return
            }
            // 先在后台确定实际入口边界，再一次展开；不能在开场动画中用新锚点打断过渡。
            self.panel.show(group: current, anchor: anchor, position: host.orientation)
            self.refreshWindowCaches()
            self.log.record("展开原生 Dock 分组：\(current.name)")
        }
    }

    /// 应用栏上悬停到运行中的 App：交给窗口预览（停 0.3 秒弹出，与右键菜单一样指向此刻放大后的图标）；其他条目或离开只取消待弹出的预览。
    private func barHoverChanged(_ id: String?) {
        guard let id, case .app(let app)? = item(id), ShelfAppActions.running(app) != nil else {
            WindowPreviewController.shared.hover(nil, source: .bar) { nil }
            return
        }
        WindowPreviewController.shared.hover(app, source: .bar) { [weak self] in
            self?.bar.previewAnchor(for: id, nearAppKitPoint: NSEvent.mouseLocation)
        }
    }

    private func contextMenu(_ id: String) -> NSMenu {
        // 与原生 Dock 一致：栏上任何图标或空白处弹右键菜单（右键、Control 点按、长按）时，先收起已展开的分组和文件夹。
        panel.hide(reason: "bar-menu")
        filesPanel.hide(reason: "bar-menu")
        if id == "system:settings" { return settingsMenu() }
        var menu = NSMenu()
        if let entry = minimizedWindows[id] {
            menu.addItem(ShelfMenuItem("显示窗口") { AppWindowService.shared.select(entry.window, in: entry.application) })
            menu.addItem(ShelfMenuItem("打开 / 切换应用") { ShelfAppActions.open(entry.application) })
        } else if id.hasPrefix("system:") {
            menu.addItem(ShelfMenuItem("打开") { [weak self] in self?.openItem(id, point: .zero) })
            if id == "system:trash" {
                // 与原生 Dock 一致：废纸篓空着时灰显；读不到废纸篓时照常可点，空着的话访达什么也不做。
                let empty = ShelfMenuItem("清倒废纸篓") { [weak self] in self?.emptyTrash() }
                empty.isEnabled = trashIsEmpty != true
                menu.addItem(empty)
            }
        } else if let file = store.configuration.files?.first(where: { $0.id == id }) {
            menu.addItem(ShelfMenuItem(file.isDirectory ? "展开文件夹" : "打开") { [weak self] in self?.openItem(id, point: .zero) })
            menu.addItem(ShelfMenuItem("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) })
            menu.addItem(ShelfMenuItem("从应用栏移除") { [weak self] in self?.removeItem(id) })
        } else if let item = item(id) {
            switch item {
            case .group(let groupID):
                menu.addItem(ShelfMenuItem("展开分组") { [weak self] in self?.openItem(id, point: CGEvent(source: nil)?.location ?? .zero) })
                menu.addItem(ShelfMenuItem("编辑 / 重命名分组…") { [weak self] in self?.showManager(selectedID: groupID) })
                menu.addItem(ShelfMenuItem("解散分组") { [weak self] in self?.dissolveGroup(groupID) })
            case .app(let app):
                var extra: [NSMenuItem] = []
                if app.path != finderPath {
                    let pinned = store.configuration.items.contains(item)
                    extra.append(ShelfMenuItem(pinned ? "从应用栏移除" : "保留在应用栏") { [weak self] in
                        guard let self else { return }; var next = self.store.configuration
                        if pinned { next.items.removeAll { $0.id == id } } else { next.items.append(item) }
                        self.apply(next, message: pinned ? "已取消固定；运行时仍会显示。" : "已固定到应用栏。")
                    })
                    // “最近使用的 App”里的图标没有在运行，没有退出可选；给出移除，免得只能等它被挤出去。
                    if !pinned, ShelfAppActions.running(app) == nil,
                       store.configuration.recentApplications?.contains(where: { $0.path == app.path }) == true {
                        extra.append(ShelfMenuItem("从应用栏移除") { [weak self] in
                            guard let self else { return }; var next = self.store.configuration
                            next.recentApplications?.removeAll { $0.path == app.path }
                            self.apply(next, message: "已从最近使用中移除。")
                        })
                    }
                }
                menu = ShelfAppActions.applicationMenu(app, extraItems: extra)
            }
        }
        // 与原生 Dock 一致：应用栏设置只在栏的空白处右键出现（system:settings），图标菜单里不放。
        return menu
    }

    /// 由访达清倒。访达收到其他程序的清倒请求不会再确认（macOS 27 实测：允许控制访达后 13 毫秒即开始删除），
    /// 确认框由应用栏按访达“清倒废纸篓之前显示警告”设置先弹出，文字取自访达。
    /// 访达清倒期间要一直等它回复，放在后台线程发送；第一次使用时系统会询问是否允许控制访达。
    private func emptyTrash() {
        guard !emptyingTrash else { return }
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        if CFPreferencesCopyAppValue("WarnOnEmptyTrash" as CFString, "com.apple.finder" as CFString) as? Bool != false {
            let alert = NSAlert()
            alert.messageText = "确定要永久抹掉废纸篓中的项目吗？"
            alert.informativeText = "此操作无法撤销。"
            alert.icon = NSImage(named: NSImage.trashFullName)
            alert.addButton(withTitle: "清倒废纸篓").hasDestructiveAction = true
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            guard runConfirmation(alert, cancel: .alertSecondButtonReturn) == .alertFirstButtonReturn else { log.record("清倒废纸篓：已取消"); return }
        }
        emptyingTrash = true
        log.record("清倒废纸篓：已请访达执行")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
            let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            var status = finder.aeDesc.map { AEDeterminePermissionToAutomateTarget($0, code("fndr"), code("empt"), true) } ?? OSStatus(procNotFound)
            if status == noErr {
                let event = NSAppleEventDescriptor(eventClass: code("fndr"), eventID: code("empt"), targetDescriptor: finder,
                                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                do { _ = try event.sendEvent(options: [.waitForReply, .canInteract, .canSwitchLayer], timeout: TimeInterval(kNoTimeOut)) }
                catch { status = OSStatus((error as NSError).code) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishEmptyingTrash(status) } }
        }
    }

    private func finishEmptyingTrash(_ status: OSStatus) {
        emptyingTrash = false
        switch status {
        case noErr:
            log.record("清倒废纸篓：完成"); refreshBar()
        case OSStatus(userCanceledErr):
            log.record("清倒废纸篓：已在访达中取消")
        case OSStatus(errAEEventNotPermitted):
            log.record("清倒废纸篓：没有控制访达的权限")
            ShelfAppActions.showError(title: "无法清倒废纸篓",
                                      message: "“DockApex”要请访达清倒废纸篓。请在“系统设置 › 隐私与安全性 › 自动化”中，为“DockApex”打开“访达”。")
        default:
            // 废纸篓已空等情况访达会返回错误；访达自己会提示无法删除的项目，这里只记日志。
            log.record("清倒废纸篓：未完成（错误 \(status)）")
        }
    }

    private func selectDisplay(mode: DockDisplayMode, uuid: String?) {
        guard let store else { return }
        var next = store.configuration
        var options = next.options ?? nativeOptions()
        options.displayMode = mode; options.displayUUID = uuid
        next.options = options
        panel.hide(); filesPanel.hide()
        apply(next, message: "显示屏设置已更新。")
    }

    /// 系统标准“关于”面板（与 ProNotch 一致）：图标、版本、版权取自 Info.plist；credits 区放署名和可点的 GitHub
    /// 链接。名称要显式给，否则会显示 CFBundleName（DockFolders）。本应用没有 Dock 图标，普通激活请求
    /// 可能不生效（见确认框），所以用 ignoringOtherApps 把关于面板带到最前。
    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "作者：Daliang\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/DaliangPro/DockApex",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://github.com/DaliangPro/DockApex")!]))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DockApex", .credits: credits])
    }

    private func showAnimationPermissions() {
        let alert = NSAlert()
        alert.messageText = "窗口动画状态"
        let capture = CGPreflightScreenCaptureAccess() ? "已授权" : "未授权"
        let accessibility = AXIsProcessTrusted() ? "已授权" : "未授权"
        let status = usesExperimentalMinimization
            ? "受控实验模式：窗口图像只缓存在本机内存，不保存或上传。"
            : "当前保留 macOS 系统窗口动画。让所有窗口缩到本应用栏的功能尚未通过实测，暂未启用，当前不捕捉窗口图像。"
        alert.informativeText = "\(status)\n\n屏幕捕捉：\(capture)\n辅助功能：\(accessibility)"
        alert.addButton(withTitle: "关闭")
        NSApp.activate()
        _ = alert.runModal()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "DockApex 设置" else { return }
        let updated = settingsMenu()
        // 菜单追踪期间保留项目身份，AX 与鼠标当前指向的项目才不会失效。
        updateMenuStates(menu, from: updated)
    }

    private func updateMenuStates(_ menu: NSMenu, from updated: NSMenu) {
        for (item, next) in zip(menu.items, updated.items) {
            item.state = next.state
            item.isEnabled = next.isEnabled
            if item.identifier?.rawValue == "display-selection", let submenu = item.submenu, let fresh = next.submenu {
                let keys = submenu.items.map { $0.identifier?.rawValue ?? $0.title }
                let freshKeys = fresh.items.map { $0.identifier?.rawValue ?? $0.title }
                if keys != freshKeys {
                    submenu.removeAllItems()
                    for freshItem in Array(fresh.items) { fresh.removeItem(freshItem); submenu.addItem(freshItem) }
                    continue
                }
            }
            if let view = item.view as? ShelfMenuSlider, let fresh = next.view as? ShelfMenuSlider {
                view.update(value: fresh.slider.doubleValue, range: fresh.slider.minValue...fresh.slider.maxValue)
            }
            if let submenu = item.submenu, let nextSubmenu = next.submenu { updateMenuStates(submenu, from: nextSubmenu) }
        }
    }

    /// 菜单滑块：一次拖动只记一步撤销（上次拖动停下超过 1 秒才算新的一次）；拖动中最多每 0.05 秒刷新一次应用栏。
    private var sliderChangedAt: TimeInterval = 0
    private var sliderRefresh: DispatchWorkItem?
    private func applySlider(finished: Bool, message: String, _ change: (inout ShelfOptions) -> Void) {
        guard let store else { return }
        var next = store.configuration
        var options = next.options ?? nativeOptions()
        change(&options)
        guard options != next.options else { return }
        next.options = options
        let now = ProcessInfo.processInfo.systemUptime
        do { try store.save(next, recordUndo: now - sliderChangedAt > 1) } catch { showError(error); return }
        sliderChangedAt = now
        if sliderRefresh == nil || finished {
            sliderRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.sliderRefresh = nil; self?.refreshBar() }
            sliderRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (finished ? 0 : 0.05), execute: work)
        }
        if finished { log?.record(message) }
    }

    private func sizeSliderChanged(_ value: Double, finished: Bool, in menu: NSMenu?) {
        // 只改应用栏；放大尺寸小于图标大小时等于不放大，与原生一致。系统 Dock 的大小留给对准最小化落点用，不写。
        applySlider(finished: finished, message: "Dock 大小改为 \(Int(value)) 点。") { options in options.iconSize = value }
        // “放大”滑块的最左端是当前图标大小（再往左就是不放大），跟着调。
        if let options = store?.configuration.options,
           let slider = menu?.items.first(where: { $0.identifier?.rawValue == "magnification-slider" })?.view as? ShelfMenuSlider {
            slider.update(value: options.magnification ? options.maximumIconSize : options.iconSize, range: options.iconSize...128)
        }
    }

    private func magnificationSliderChanged(_ value: Double, finished: Bool) {
        var enabled = false, size = 0.0
        applySlider(finished: finished, message: "悬停放大改为 \(value > (store?.configuration.options?.iconSize ?? 0) ? "\(Int(value)) 点" : "关")。") { options in
            enabled = value > options.iconSize
            options.magnification = enabled
            if enabled { options.maximumIconSize = value }
            size = options.maximumIconSize
        }
        // 写给系统 Dock，跟随系统设置时读回来的是同一个值；影子模式下系统 Dock 的放大由会话管着，不写。
        // 拖动中最多每 0.1 秒写一次，松手时立即写。
        guard canAdjustHiddenDock, !usesNativeHost, store?.configuration.options?.magnification == enabled else { return }
        pendingMagnification = (enabled, size)
        guard magnificationWrite == nil || finished else { return }
        magnificationWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.magnificationWrite = nil
            guard let pending = self.pendingMagnification, self.canAdjustHiddenDock else { return }
            self.pendingMagnification = nil
            CoreDockMagnification.set(enabled: pending.enabled, size: pending.size)
            CoreDockAutoHide.set(true)
        }
        magnificationWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (finished ? 0 : 0.1), execute: work)
    }
    private var pendingMagnification: (enabled: Bool, size: Double)?
    private var magnificationWrite: DispatchWorkItem?

    private func showManager(selectedID: UUID? = nil) { manager.show(groups: store.configuration.groups, status: status, selectedID: selectedID) }
    private func quit() { NSApp.terminate(nil) }

    private func setStatus(_ text: String) {
        status = text
        log?.record(text)
        manager.refresh(groups: store.configuration.groups, status: text)
    }

    private func showError(_ error: Error) {
        log?.record("错误：\(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "DockApex"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }
}
