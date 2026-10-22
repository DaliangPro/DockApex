import AppKit
import UniformTypeIdentifiers

// 本程序只观察拖放事件，不执行收到的文件，也不修改 Dock 或默认打开方式。
@MainActor
final class ProbeRecorder {
    let role: String
    let logURL: URL
    private(set) var eventCount = 0
    private(set) var receiveCount = 0
    var onUpdate: (() -> Void)?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        role = info["ProbeRole"] as? String ?? "未知"
        let root = info["ProbeRoot"] as? String ?? Bundle.main.bundleURL.deletingLastPathComponent().path
        logURL = URL(fileURLWithPath: root).appendingPathComponent("logs/\(role == "拖拽源 A" ? "source" : "target")-events.jsonl")
    }

    func record(_ event: String, urls: [URL] = [], detail: String = "", received: Bool = false) {
        eventCount += 1
        if received { receiveCount += 1 }
        let files = urls.map { url -> [String: String] in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? "未知"
            // 只记录文件名和类型，不保存文件内容、父目录或完整 URL。
            return ["name": url.isFileURL ? url.lastPathComponent : "非文件 URL", "type": type]
        }
        let entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "role": role,
            "event": event,
            "eventCount": eventCount,
            "receiveCount": receiveCount,
            "files": files,
            "detail": detail
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: logURL.path) {
                _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 失败只显示在窗口，避免改写到工作区外的备用日志位置。
            NSApplication.shared.mainWindow?.subtitle = "日志写入失败：\(error.localizedDescription)"
        }
        onUpdate?()
    }
}

@MainActor
final class ProbeDropView: NSView {
    let recorder: ProbeRecorder
    let surface: String

    init(frame: NSRect, recorder: ProbeRecorder, surface: String) {
        self.recorder = recorder
        self.surface = surface
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL])
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { nil }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        recorder.record("\(surface).draggingEntered", urls: urls(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        recorder.record("\(surface).draggingExited")
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        recorder.record("\(surface).prepareForDragOperation", urls: urls(sender))
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        recorder.record("\(surface).performDragOperation", urls: urls(sender), received: true)
        return true
    }
}

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let recorder = ProbeRecorder()
    var window: NSWindow?
    var countsLabel: NSTextField?
    var dockView: ProbeDropView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isSource = recorder.role == "拖拽源 A"
        let letter = isSource ? "A" : "B"
        let color = isSource ? NSColor.systemBlue : NSColor.systemOrange
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: 52, yRadius: 52).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 160), .foregroundColor: NSColor.white]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        NSApplication.shared.applicationIconImage = image

        let content = ProbeDropView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), recorder: recorder, surface: "window")
        let title = NSTextField(labelWithString: "Dock 拖放探针 · \(recorder.role)")
        title.font = .boldSystemFont(ofSize: 25)
        let identity = NSTextField(labelWithString: "\(Bundle.main.bundleIdentifier ?? "未知 Bundle ID")")
        identity.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let instructions = NSTextField(wrappingLabelWithString: "目标测试：把系统 Dock 中的蓝色 A 图标拖到橙色 B 图标上。\n对照测试：把 Finder 中的 A.app 拖到 Dock 中的 B 图标上。\n本窗口也可接收文件，作为拖放记录器的对照。收到文件只记录名称和类型。")
        instructions.font = .systemFont(ofSize: 15)
        let counts = NSTextField(labelWithString: "事件：0；接收：0")
        counts.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        countsLabel = counts
        let log = NSTextField(wrappingLabelWithString: "日志：\(recorder.logURL.path)")
        log.font = .systemFont(ofSize: 11)
        log.isSelectable = true
        let quit = NSButton(title: "退出此探针", target: self, action: #selector(quitProbe))
        quit.bezelStyle = .rounded
        let stack = NSStackView(views: [title, identity, instructions, counts, log, quit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DockProbe\(isSource ? "Source" : "Target") · \(recorder.role)"
        window.contentView = content
        window.delegate = self
        window.setFrameOrigin(NSPoint(x: isSource ? 60 : 730, y: 300))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        recorder.onUpdate = { [weak self] in
            guard let self else { return }
            self.countsLabel?.stringValue = "事件：\(self.recorder.eventCount)；接收：\(self.recorder.receiveCount)"
        }

        // 自定义 Dock 内容视图用于观察 AppKit 是否转发拖放回调；不假定会转发。
        let dockView = ProbeDropView(frame: NSRect(x: 0, y: 0, width: 128, height: 128), recorder: recorder, surface: "dockTile")
        let iconView = NSImageView(frame: dockView.bounds)
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        dockView.addSubview(iconView)
        self.dockView = dockView
        NSApplication.shared.dockTile.contentView = dockView
        NSApplication.shared.dockTile.display()

        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出此探针", action: #selector(quitProbe), keyEquivalent: "q").target = self
        let menuItem = NSMenuItem()
        menuItem.submenu = appMenu
        menu.addItem(menuItem)
        NSApplication.shared.mainMenu = menu
        recorder.record("applicationDidFinishLaunching")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        recorder.record("application.openFiles", urls: filenames.map { URL(fileURLWithPath: $0) }, received: true)
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        recorder.record("application.openURLs", urls: urls, received: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        recorder.record("applicationShouldHandleReopen", detail: "hasVisibleWindows=\(flag)")
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.record("applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func quitProbe() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
