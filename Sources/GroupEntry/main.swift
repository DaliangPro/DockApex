import AppKit

/// 每个固定入口是无窗口的 accessory 代理。预热后点击只发送 reopen，不反复启动退出。
@MainActor
final class GroupEntryDelegate: NSObject, NSApplicationDelegate {
    private struct FocusTarget {
        let pid: pid_t
        let launchTime: TimeInterval
        let appPath: String

        init?(_ app: NSRunningApplication) {
            guard let launchTime = app.launchDate?.timeIntervalSince1970, let url = app.bundleURL else { return nil }
            pid = app.processIdentifier
            self.launchTime = launchTime
            appPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        }

        func runningApplication() -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  let actualStart = app.launchDate?.timeIntervalSince1970, abs(actualStart - launchTime) < 0.000_001,
                  app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == appPath else { return nil }
            return app
        }
    }

    private var activation = GroupEntryActivationGate()
    private let preparesOnly = CommandLine.arguments.contains("--dockfolders-prepare")
    private var ownerMonitor: DispatchSourceProcess?
    private var ownerPID: pid_t?
    private var previousFocus: FocusTarget?
    private var focusObserver: NSObjectProtocol?
    private var focusGeneration = 0

    override init() {
        super.init()
        rememberForeground(NSWorkspace.shared.frontmostApplication)
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    self?.rememberForeground(pid.flatMap { NSRunningApplication(processIdentifier: $0) })
                }
            }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if preparesOnly {
            guard let owner = GroupEntryOwnerRequest(arguments: CommandLine.arguments),
                  watchOwner(pid: owner.processIdentifier, launchTime: owner.launchTime) else {
                NSApp.terminate(nil)
                return
            }
        }
        if activation.didFinishLaunching(preparesOnly: preparesOnly, now: ProcessInfo.processInfo.systemUptime) { openGroup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if activation.reopen(now: ProcessInfo.processInfo.systemUptime) { openGroup() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillBecomeActive(_ notification: Notification) { returnFocusAfterActivation() }
    func applicationDidBecomeActive(_ notification: Notification) { returnFocusAfterActivation() }

    func applicationWillTerminate(_ notification: Notification) {
        focusGeneration &+= 1
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        focusObserver = nil
        ownerMonitor?.cancel()
        ownerMonitor = nil
    }

    private func isUserApplication(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != "com.apple.dock", app.bundleIdentifier != "io.daliang.dockfolders",
              app.bundleIdentifier?.hasPrefix("local.dockfolders.group.") != true else { return false }
        if let mainPath = Bundle.main.object(forInfoDictionaryKey: "DockFoldersMainAppPath") as? String,
           app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: mainPath).standardizedFileURL.resolvingSymlinksInPath() { return false }
        return true
    }

    private func rememberForeground(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // 任何其他应用的激活都取消旧交还任务，包括主工具或另一个分组代理。
        focusGeneration &+= 1
        if isUserApplication(app), let target = FocusTarget(app) { previousFocus = target }
    }

    private func returnFocusAfterActivation() {
        focusGeneration &+= 1
        let token = focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.focusGeneration, NSApp.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  let target = self.previousFocus?.runningApplication(), self.isUserApplication(target) else { return }
            // 无窗口入口不保留输入焦点；合作交还给此前的用户应用，不强制抢占后续切换。
            NSApp.yieldActivation(to: target)
            _ = target.activate()
        }
    }

    private func watchOwner(pid: pid_t, launchTime: TimeInterval) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let actualStart = app.launchDate?.timeIntervalSince1970, abs(actualStart - launchTime) < 0.000_001,
              let mainPath = Bundle.main.object(forInfoDictionaryKey: "DockFoldersMainAppPath") as? String,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: mainPath).standardizedFileURL.resolvingSymlinksInPath() else { return false }
        if ownerPID == pid { return true }
        ownerMonitor?.cancel()
        ownerPID = pid
        // 内核仅在这个已核验的主进程退出时唤醒代理，没有计时器或后台扫描。
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.ownerPID == pid else { return }
                NSApp.terminate(nil)
            }
        }
        ownerMonitor = source
        source.activate()
        return true
    }

    private func openGroup() {
        guard let mainPath = Bundle.main.object(forInfoDictionaryKey: "DockFoldersMainAppPath") as? String,
              let id = Bundle.main.object(forInfoDictionaryKey: "DockFoldersGroupID") as? String,
              UUID(uuidString: id) != nil,
              let url = URL(string: "dockfolders://group/\(id)") else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: mainPath), configuration: configuration) { [weak self] opened, error in
            let pid = opened?.processIdentifier
            let launchTime = opened?.launchDate?.timeIntervalSince1970
            // 成功后保留这个无窗口代理，下一次点击通过 reopen 再次转发。
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard !failed, let self, let pid, let launchTime, self.watchOwner(pid: pid, launchTime: launchTime) else {
                    NSApp.terminate(nil)
                    return
                }
            }
        }
    }
}

let application = NSApplication.shared
let delegate = GroupEntryDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
withExtendedLifetime(delegate) {}
