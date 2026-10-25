import AppKit
@preconcurrency import ScreenCaptureKit

/// 窗口预览：指针停在运行中的 App 上约 0.3 秒，在图标上方弹出它当前的窗口，每个窗口一张缩略图和标题，点按切到那个窗口。
/// 应用栏和分组面板里的 App 都支持。预览开着时移到别的 App 立即换内容；指针离开图标、预览和两者之间的通道 0.25 秒后收起。
/// 与右键菜单一样用系统弹出框承载：弹出、收起动画，箭头和材质都和右键菜单一致。
/// 缩略图只在悬停时用 ScreenCaptureKit 截取单个窗口，只存在内存里（不存盘、不上传），窗口关掉或 App 退出就丢掉；
/// 最小化的窗口照样截（单窗口截取在最小化后仍能拿到画面，10-24 实测）；截到全透明的空画面就沿用上一张，没有就显示 App 图标。
@MainActor
final class WindowPreviewController: NSObject, NSPopoverDelegate {
    static let shared = WindowPreviewController()
    enum Source { case bar, group }
    /// 弹出位置：与右键菜单相同的定位视图、图标矩形和弹出方向。
    struct Anchor {
        let view: NSView
        let rect: NSRect
        let edge: NSRectEdge
    }

    private(set) var isShown = false
    /// 预览出现时调用：应用栏、分组面板据此收起名称提示（预览里已有窗口标题）。
    var onShown: (() -> Void)?
    private var popover: NSPopover?
    private var grid: WindowPreviewGridView?
    private weak var anchorView: NSView?
    private var anchorRect = NSRect.zero
    private var anchorEdge = NSRectEdge.maxY
    private var app: AppReference?
    private var source = Source.bar
    private var pendingShow: DispatchWorkItem?
    private var currentAnchor: (@MainActor () -> Anchor?)?
    private var generation = 0
    private var leaveTimer: Timer?
    private var outsideSince: TimeInterval?
    private var monitors: [Any] = []
    private var captureTask: Task<Void, Never>?
    private var thumbnails: [CGWindowID: (pid: pid_t, image: CGImage)] = [:]

    /// 指针停在某个 App 上；app 为 nil 表示移到了别处，只取消待弹出的预览，已开着的由离开计时判断（指针可能正移向预览）。
    /// anchor 在弹出那一刻才取，图标那时已放大到位，预览不会压住它。
    func hover(_ app: AppReference?, source: Source, anchor: @escaping @MainActor () -> Anchor?) {
        pendingShow?.cancel(); pendingShow = nil
        guard let app else { return }
        if isShown {
            if app.path != self.app?.path || source != self.source { load(app, source: source, anchor: anchor) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.load(app, source: source, anchor: anchor) }
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 窗口是否是预览弹出框（分组面板据此不把点预览当成点外面）。
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === grid?.window }

    /// 仅诊断：只记数量与状态，不记窗口标题（属于用户内容）。
    var summary: [String: Any] {
        ["shown": isShown, "source": source == .bar ? "bar" : "group", "app": app.map { ($0.path as NSString).lastPathComponent } ?? "",
         "tiles": grid?.tileCount ?? 0, "tilesWithThumbnail": grid?.thumbnailCount ?? 0, "cachedThumbnails": thumbnails.count,
         "frame": grid?.window.map { NSStringFromRect($0.frame) } ?? ""]
    }

    func hide() {
        pendingShow?.cancel(); pendingShow = nil
        generation += 1
        captureTask?.cancel(); captureTask = nil
        leaveTimer?.invalidate(); leaveTimer = nil; outsideSince = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        guard isShown else { return }
        isShown = false
        app = nil
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === popover else { return }
        popover = nil; grid = nil
        if isShown { hide() }
    }

    private func load(_ app: AppReference, source: Source, anchor: @escaping @MainActor () -> Anchor?) {
        currentAnchor = anchor
        generation += 1
        let token = generation
        AppWindowService.shared.refresh(app) { [weak self] snapshot in
            guard let self, self.generation == token else { return }
            let windows = Array(snapshot.windows.prefix(WindowPreviewGridView.maxWindows))
            self.prune(pid: snapshot.processIdentifier, keeping: Set(snapshot.windows.compactMap(\.cgWindowID)))
            guard !windows.isEmpty, let anchor = anchor(), anchor.view.window?.isVisible == true else { self.hide(); return }
            self.present(app, windows: windows, pid: snapshot.processIdentifier, source: source, anchor: anchor, token: token)
        }
    }

    private func present(_ app: AppReference, windows: [AppWindowInfo], pid: pid_t, source: Source, anchor: Anchor, token: Int) {
        self.app = app; self.source = source
        let thumbnails = self.thumbnails.compactMapValues { $0.pid == pid ? $0.image : nil }
        let select: (AppWindowInfo) -> Void = { [weak self] window in
            AppWindowService.shared.select(window, in: app)
            self?.hide()
        }
        // 关闭按钮：按窗口自己的关闭按钮，不切过去；等关闭动画走完再刷新，没窗口了就收起。
        // 有未存内容时应用会弹存储提示、窗口还在，刷新后仍会列出。
        let close: (AppWindowInfo) -> Void = { window in
            AppWindowService.shared.close(window, in: app) { [weak self] result in
                guard result.succeeded else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isShown, self.app?.path == app.path, let anchor = self.currentAnchor else { return }
                    self.load(app, source: self.source, anchor: anchor)
                }
            }
        }
        // 同一个定位视图（同一条应用栏、同一个分组面板）里换 App：原地换内容并挪箭头，不重新弹出。
        if let popover, popover.isShown, let grid, anchorView === anchor.view {
            grid.configure(windows: windows, thumbnails: thumbnails, appIcon: ShelfAppActions.icon(app), onSelect: select, onClose: close)
            popover.contentSize = grid.preferredSize
            popover.positioningRect = anchor.rect
        } else {
            popover?.close()
            let grid = WindowPreviewGridView()
            grid.configure(windows: windows, thumbnails: thumbnails, appIcon: ShelfAppActions.icon(app), onSelect: select, onClose: close)
            let controller = NSViewController()
            controller.view = grid
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.contentSize = grid.preferredSize
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.delegate = self
            self.popover = popover; self.grid = grid
            popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
            // 点选、点关闭时不激活本应用、不抢走当前 App 的键盘焦点。
            if let panel = grid.window as? NSPanel { panel.preventActivation(); panel.becomesKeyOnlyIfNeeded = true }
        }
        anchorView = anchor.view; anchorRect = anchor.rect; anchorEdge = anchor.edge
        if !isShown {
            isShown = true
            installMonitors()
            onShown?()
        }
        capture(windows, pid: pid, token: token)
    }

    /// 离开判定：指针在图标、预览和两者之间的通道以外持续 0.25 秒才收起，留出从图标移到预览的路上时间。
    /// 点按别处（其他 App 或本应用的其他窗口）立即收起。
    private func installMonitors() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkPointer() } }
        RunLoop.main.add(timer, forMode: .common)
        leaveTimer = timer
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.owns(event.window) else { return }
                self.hide()
            }
            return event
        }) { monitors.append(local) }
    }

    private func checkPointer() {
        guard isShown, let window = grid?.window, let view = anchorView, let host = view.window else { return }
        let point = NSEvent.mouseLocation
        let anchor = host.convertToScreen(view.convert(anchorRect, to: nil))
        let hull = anchor.union(window.frame)
        let corridor = anchorEdge == .maxY || anchorEdge == .minY
            ? CGRect(x: anchor.minX - 10, y: hull.minY, width: anchor.width + 20, height: hull.height)
            : CGRect(x: hull.minX, y: anchor.minY - 10, width: hull.width, height: anchor.height + 20)
        if window.frame.insetBy(dx: -8, dy: -8).contains(point) || corridor.contains(point) { outsideSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = outsideSince { if now - since > 0.25 { hide() } } else { outsideSince = now }
    }

    /// 后台逐个截取窗口，含最小化的（单窗口截取，不含阴影，长边 480 像素），截到一张就换上一张。
    /// 截取不在主线程上做：截图接口每个进程第一次用时，会在调用线程上新建音频时钟、初始化 CoreAudio，
    /// 放在主线程会让每次启动后第一次悬停卡约 0.2 秒（10-24 卡顿栈里 16 个进程各 1 次）。只有换缩略图回主线程。
    private func capture(_ windows: [AppWindowInfo], pid: pid_t, token: Int) {
        captureTask?.cancel()
        let targets = windows.compactMap { info in info.cgWindowID.map { (number: $0, frame: info.quartzFrame) } }
        guard !targets.isEmpty else { return }
        captureTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            for target in targets {
                guard !Task.isCancelled else { return }
                guard let window = content.windows.first(where: { $0.windowID == target.number && $0.owningApplication?.processID == pid }) else { continue }
                let size = target.frame?.size ?? window.frame.size
                guard size.width > 20, size.height > 20 else { continue }
                let scale = min(1, 480 / max(size.width, size.height))
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(size.width * scale)); configuration.height = max(1, Int(size.height * scale))
                configuration.showsCursor = false; configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true; configuration.shouldBeOpaque = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                              configuration: configuration),
                      Self.hasVisiblePixels(image), !Task.isCancelled else { continue }
                await self?.store(image, for: target.number, pid: pid, token: token)
            }
        }
    }

    private func store(_ image: CGImage, for number: CGWindowID, pid: pid_t, token: Int) {
        thumbnails[number] = (pid, image)
        if generation == token { grid?.setThumbnail(image, for: number) }
    }

    /// 缩到 8×8 看有没有不透明的点。
    nonisolated private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return stride(from: 3, to: buffer.count, by: 4).contains { buffer[$0] > 8 }
        }
    }

    /// 只留这个进程现存窗口的缩略图；总数超过 64 张时清空重来，内存里不长期攒画面。
    private func prune(pid: pid_t, keeping alive: Set<CGWindowID>) {
        thumbnails = thumbnails.filter { $0.value.pid != pid || alive.contains($0.key) }
        thumbnails = thumbnails.filter { NSRunningApplication(processIdentifier: $0.value.pid) != nil }
        if thumbnails.count > 64 { thumbnails.removeAll() }
    }
}

/// 预览面板内容：每行最多 4 个窗口，缩略图等比放进固定框，下面一行标题；最小化的标出来。
@MainActor
final class WindowPreviewGridView: NSView {
    static let maxWindows = 12
    private static let padding: CGFloat = 10, spacing: CGFloat = 8, columns = 4
    private var tiles: [WindowPreviewTile] = []

    override var isFlipped: Bool { true }

    var preferredSize: CGSize {
        let count = max(1, tiles.count), columns = min(count, Self.columns)
        let rows = (count + Self.columns - 1) / Self.columns
        let tile = WindowPreviewTile.size
        return CGSize(width: CGFloat(columns) * tile.width + CGFloat(columns - 1) * Self.spacing + Self.padding * 2,
                      height: CGFloat(rows) * tile.height + CGFloat(rows - 1) * Self.spacing + Self.padding * 2)
    }

    func configure(windows: [AppWindowInfo], thumbnails: [CGWindowID: CGImage], appIcon: NSImage,
                   onSelect: @escaping (AppWindowInfo) -> Void, onClose: @escaping (AppWindowInfo) -> Void) {
        for tile in tiles { tile.removeFromSuperview() }
        tiles = windows.map { window in
            let tile = WindowPreviewTile(window: window, image: window.cgWindowID.flatMap { thumbnails[$0] }, appIcon: appIcon)
            tile.onSelect = { onSelect(window) }
            tile.onClose = { onClose(window) }
            addSubview(tile)
            return tile
        }
        needsLayout = true
    }

    var tileCount: Int { tiles.count }
    var thumbnailCount: Int { tiles.filter(\.hasThumbnail).count }

    func setThumbnail(_ image: CGImage, for number: CGWindowID) {
        tiles.first { $0.info.cgWindowID == number }?.setImage(image)
    }

    override func layout() {
        super.layout()
        let tile = WindowPreviewTile.size
        for (index, view) in tiles.enumerated() {
            let column = index % Self.columns, row = index / Self.columns
            view.frame = CGRect(x: Self.padding + CGFloat(column) * (tile.width + Self.spacing),
                                y: Self.padding + CGFloat(row) * (tile.height + Self.spacing), width: tile.width, height: tile.height)
        }
    }
}

@MainActor
private final class WindowPreviewTile: NSView {
    static let thumbnail = CGSize(width: 176, height: 110)
    static let size = CGSize(width: thumbnail.width, height: thumbnail.height + 21)
    let info: AppWindowInfo
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)? { didSet { closeButton.onPress = onClose } }
    /// 关闭按钮贴在缩略图框（灰色圆角框）的右上角，上、右各留 4 点，不随画面大小移动。
    private let closeButton = WindowPreviewCloseButton(frame: CGRect(x: WindowPreviewTile.thumbnail.width - 22, y: 4, width: 18, height: 18))
    private let appIcon: NSImage
    private let imageLayer = CALayer()
    private let title = NSTextField(labelWithString: "")
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true; closeButton.isHidden = !hovered } } }
    private(set) var hasThumbnail = false

    override var isFlipped: Bool { true }

    init(window: AppWindowInfo, image: CGImage?, appIcon: NSImage) {
        self.info = window
        self.appIcon = appIcon
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 5
        imageLayer.masksToBounds = true
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        title.stringValue = (window.title.isEmpty ? "未命名窗口" : window.title) + (window.isMinimized ? "（已最小化）" : "")
        title.font = .systemFont(ofSize: 10)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.alignment = .center
        addSubview(title)
        closeButton.isHidden = true
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title.stringValue)
        setImage(image)
    }

    required init?(coder: NSCoder) { nil }

    /// 有画面就等比放进缩略图框；没有（还没截到、截取失败）就在框中间放 App 图标。
    func setImage(_ image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let box = CGRect(origin: .zero, size: Self.thumbnail)
        hasThumbnail = image != nil
        if let image {
            imageLayer.contents = image
            let ratio = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
            let fitted = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
            imageLayer.frame = CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
            imageLayer.cornerRadius = 5
        } else {
            imageLayer.contents = appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            imageLayer.frame = CGRect(x: box.midX - 26, y: box.midY - 26, width: 52, height: 52)
            imageLayer.cornerRadius = 0
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        title.frame = CGRect(x: 0, y: Self.thumbnail.height + 5, width: bounds.width, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = CGRect(origin: .zero, size: Self.thumbnail).insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
        (hovered ? NSColor.labelColor.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        path.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }
}

extension NSPanel {
    /// 系统弹出框的窗口由 AppKit 建好，事后加 nonactivatingPanel 只改了样式位，防激活标记仍是关的（10-23 实测），
    /// 点一下照样激活本应用；再用内部方法把标记补上，系统不支持时只保留样式位。
    func preventActivation() {
        styleMask.insert(.nonactivatingPanel)
        let selector = Selector(("_setPreventsActivation:"))
        guard responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, true)
    }
}

/// 预览格子右上角的关闭按钮：深色圆底白叉，指针移上去变红，松开即关闭对应窗口。
@MainActor
private final class WindowPreviewCloseButton: NSView {
    var onPress: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("关闭窗口")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (hovered ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.55)).setFill()
        circle.fill()
        let inset = bounds.width * 0.33
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: inset, y: inset)); cross.line(to: CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        cross.move(to: CGPoint(x: bounds.maxX - inset, y: inset)); cross.line(to: CGPoint(x: inset, y: bounds.maxY - inset))
        cross.lineWidth = 1.6; cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }

    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}
