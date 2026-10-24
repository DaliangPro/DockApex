import AppKit
import QuartzCore

/// 玻璃、列表及滚动条统一在内层圆角路径内合成；外层仅承载来源到目标的变换。
/// 不能只给 NSGlassEffectView 设置 cornerRadius：其内容与旧版材质仍可能画满矩形。
@MainActor
final class PopupSurfaceView: NSView {
    /// 指向入口图标的小箭头（与右键菜单浮层一致）：所在边与箭尖位置（本视图坐标）。外框已含箭头那一条，内容排在其余部分。
    struct Arrow: Equatable {
        var edge: DockPosition
        var tip: CGPoint
    }
    /// 宽度含两侧与面板边衔接的过渡曲线。
    static let arrowSize = CGSize(width: 34, height: 10)

    let content: NSView
    private let motionSurface = NSView()
    private let clippedSurface = NSView()
    private var contentFrame = CGRect.zero
    private var arrow: Arrow?
    private let material: NSView
    private let roundingMask = CAShapeLayer()
    private let radius: CGFloat
    private var presentationRevision = 0
    private var pendingModelCommit = false
    private var animationStart: (transform: CGAffineTransform, opacity: CGFloat)?
    private var animationHasStarted = false
    private var animationStartObserver: PopupAnimationStartObserver?

    override var isOpaque: Bool { false }

    init(content: NSView, radius: CGFloat) {
        self.content = content
        self.radius = radius
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            glass.contentView = content
            material = glass
        } else {
            let visualEffect = NSVisualEffectView()
            visualEffect.material = .popover
            visualEffect.state = .active
            visualEffect.blendingMode = .behindWindow
            visualEffect.addSubview(content)
            material = visualEffect
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        motionSurface.wantsLayer = true
        motionSurface.layer?.backgroundColor = NSColor.clear.cgColor
        motionSurface.layer?.isOpaque = false
        motionSurface.layer?.shadowColor = NSColor.black.cgColor
        motionSurface.layer?.shadowRadius = 12
        motionSurface.layer?.shadowOffset = CGSize(width: 0, height: -3)
        clippedSurface.wantsLayer = true
        clippedSurface.layer?.backgroundColor = NSColor.clear.cgColor
        clippedSurface.layer?.isOpaque = false
        clippedSurface.layer?.mask = roundingMask
        roundingMask.fillColor = NSColor.black.cgColor
        roundingMask.allowsEdgeAntialiasing = true
        roundingMask.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge]
        material.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        clippedSurface.addSubview(material)
        motionSurface.addSubview(clippedSurface)
        addSubview(motionSurface)
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if motionSurface.frame != contentFrame { motionSurface.frame = contentFrame }
        // AppKit 的 backing layer 不保证沿用 CALayer 初始 anchorPoint；明确固定中心后再使用纯几何变换。
        motionSurface.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        motionSurface.layer?.bounds = CGRect(origin: .zero, size: contentFrame.size)
        motionSurface.layer?.position = CGPoint(x: contentFrame.midX, y: contentFrame.midY)
        if clippedSurface.frame != motionSurface.bounds { clippedSurface.frame = motionSurface.bounds }
        if material.frame != clippedSurface.bounds { material.frame = clippedSurface.bounds }
        let body = bodyRect(in: material.bounds)
        if content.frame != body {
            content.frame = body
            content.needsLayout = true
        }
        updateMask()
        CATransaction.commit()
    }

    /// 外框去掉箭头那一条后的面板主体。
    private func bodyRect(in bounds: CGRect) -> CGRect {
        guard let arrow else { return bounds }
        let height = Self.arrowSize.height
        switch arrow.edge {
        case .bottom: return CGRect(x: bounds.minX, y: bounds.minY + height, width: bounds.width, height: bounds.height - height)
        case .left: return CGRect(x: bounds.minX + height, y: bounds.minY, width: bounds.width - height, height: bounds.height)
        case .right: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - height, height: bounds.height)
        }
    }

    /// 圆角主体连同箭头画成一条轮廓（玻璃遮罩与阴影共用）。箭头贴着入口那一边，
    /// 位置跟着入口中心走，但不进圆角范围（面板被屏幕边缘挡住、挪开时箭头仍尽量对准入口）。
    private func outline(in bounds: CGRect) -> CGPath {
        let body = bodyRect(in: bounds)
        guard let arrow, body.width > radius * 2, body.height > radius * 2 else {
            return CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let half = Self.arrowSize.width / 2, depth = Self.arrowSize.height, r = radius
        let tip = CGPoint(x: arrow.tip.x - contentFrame.minX, y: arrow.tip.y - contentFrame.minY)
        let path = CGMutablePath()
        /// 箭头两侧各一段三次曲线：起点与面板边相切（与边缘圆滑衔接），到箭尖时水平收拢（箭尖成圆弧），没有折角。
        /// point 把“沿边位置、离边深度”换算成坐标；sign 是轮廓沿这条边前进的方向。
        func notch(center: CGFloat, sign: CGFloat, _ point: (CGFloat, CGFloat) -> CGPoint) {
            path.addLine(to: point(center - sign * half, 0))
            path.addCurve(to: point(center, depth), control1: point(center - sign * half * 0.52, 0),
                          control2: point(center - sign * half * 0.34, depth))
            path.addCurve(to: point(center + sign * half, 0), control1: point(center + sign * half * 0.34, depth),
                          control2: point(center + sign * half * 0.52, 0))
        }
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if arrow.edge == .bottom {
            let x = min(max(tip.x, body.minX + r + half), body.maxX - r - half)
            notch(center: x, sign: 1) { CGPoint(x: $0, y: body.minY - $1) }
        }
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        if arrow.edge == .right {
            let y = min(max(tip.y, body.minY + r + half), body.maxY - r - half)
            notch(center: y, sign: 1) { CGPoint(x: body.maxX + $1, y: $0) }
        }
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        if arrow.edge == .left {
            let y = min(max(tip.y, body.minY + r + half), body.maxY - r - half)
            notch(center: y, sign: -1) { CGPoint(x: body.minX - $1, y: $0) }
        }
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMask()
    }

    private func updateMask() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        motionSurface.layer?.contentsScale = scale
        clippedSurface.layer?.contentsScale = scale
        roundingMask.contentsScale = scale
        roundingMask.frame = clippedSurface.bounds
        roundingMask.path = outline(in: clippedSurface.bounds)
        motionSurface.layer?.shadowPath = roundingMask.path
    }

    func contentFrameInScreen(of window: NSWindow) -> CGRect? {
        contentFrame.isEmpty ? nil : window.convertToScreen(convert(contentFrame, to: nil))
    }

    func configureContent(frame: CGRect, expandedCanvas: Bool, arrow: Arrow? = nil) {
        contentFrame = frame
        self.arrow = arrow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        motionSurface.layer?.shadowOpacity = expandedCanvas ? 0.20 : 0
        CATransaction.commit()
        needsLayout = true
    }

    /// 内层的 bounds/position 始终是最终内容矩形，只合成变换到来源图标。
    func setPresentation(transform: CGAffineTransform, opacity: Float, duration: TimeInterval,
                         fromTransform: CGAffineTransform? = nil, fromOpacity: CGFloat? = nil,
                         onCompletion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let layer = motionSurface.layer else { return }
        let observed = sampledPresentation
        let previousTransform = fromTransform ?? observed.transform
        let previousOpacity = Float(fromOpacity ?? observed.opacity)
        let target = CATransform3DMakeAffineTransform(transform)
        presentationRevision &+= 1
        let revision = presentationRevision
        pendingModelCommit = true
        animationHasStarted = false
        animationStart = duration > 0 ? (previousTransform, CGFloat(previousOpacity)) : nil
        animationStartObserver = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 面板首次上屏时 AppKit 会把 backing layer 的 anchorPoint 重置为左下角，缩放会从左侧弹出；每次动画前重新固定中心。
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = CGRect(origin: .zero, size: contentFrame.size)
        layer.position = CGPoint(x: contentFrame.midX, y: contentFrame.midY)
        layer.removeAnimation(forKey: "popup-transform")
        layer.removeAnimation(forKey: "popup-opacity")
        layer.transform = target
        layer.opacity = opacity
        // 无动画时此回调只确认 model 事务已提交；产品交互完成仍立即返回。
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationRevision == revision else { return }
                self.pendingModelCommit = false
                self.animationStart = nil
                self.animationHasStarted = false
                self.animationStartObserver = nil
                if duration > 0 { onCompletion?() }
            }
        }
        if duration > 0 {
            let observer = PopupAnimationStartObserver { [weak self] in
                guard let self, self.presentationRevision == revision else { return }
                self.animationHasStarted = true
                self.pendingModelCommit = false
            }
            animationStartObserver = observer
            // 与系统弹出框（右键菜单、窗口预览）同一条曲线。10-23 逐帧采样系统弹出框窗口：从箭尖长出，透明度与缩放同步；
            // 展开约 0.20 秒到位、0.24 秒冲过约 1.7%、0.47 秒回稳（弹簧，阻尼比约 0.79、固有频率约 21.5）；
            // 收起 0.26 秒缩回箭尖、不回弹，形状与系统默认缓动曲线（0.25, 0.1, 0.25, 1）吻合。
            let opening = opacity > previousOpacity
            func curve(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
                let animation: CABasicAnimation
                if opening {
                    let spring = CASpringAnimation(keyPath: keyPath)
                    spring.mass = 1; spring.stiffness = 462; spring.damping = 34
                    spring.duration = spring.settlingDuration
                    animation = spring
                } else {
                    animation = CABasicAnimation(keyPath: keyPath)
                    animation.duration = 0.26
                    animation.timingFunction = CAMediaTimingFunction(name: .default)
                }
                animation.fromValue = from; animation.toValue = to
                return animation
            }
            let motion = curve("transform", from: NSValue(caTransform3D: CATransform3DMakeAffineTransform(previousTransform)), to: NSValue(caTransform3D: target))
            motion.delegate = observer
            let fade = curve("opacity", from: previousOpacity, to: opacity)
            layer.add(motion, forKey: "popup-transform")
            layer.add(fade, forKey: "popup-opacity")
        }
        CATransaction.commit()
        if duration <= 0 { onCompletion?() }
    }

    var sampledPresentation: (transform: CGAffineTransform, opacity: CGFloat, sampleKind: String) {
        guard let layer = motionSurface.layer else { return (.identity, 1, "unavailable") }
        if let animationStart, !animationHasStarted {
            // 新 model 已是终态，但新动画尚未启动，不能把它冒称为已呈现的终态。
            return (animationStart.transform, animationStart.opacity, "animation-pending")
        }
        if !pendingModelCommit, let presented = layer.presentation() {
            return (CATransform3DGetAffineTransform(presented.transform), CGFloat(presented.opacity), "presentation")
        }
        return (CATransform3DGetAffineTransform(layer.transform), CGFloat(layer.opacity), "model-only")
    }
}

/// CA 委托可能来自合成回调线程；只把不可变回调交回主线程，不携带 CAAnimation 跨 actor。
private final class PopupAnimationStartObserver: NSObject, CAAnimationDelegate {
    private let onStart: @MainActor @Sendable () -> Void
    init(onStart: @escaping @MainActor @Sendable () -> Void) { self.onStart = onStart }
    nonisolated func animationDidStart(_ anim: CAAnimation) {
        Task { @MainActor [onStart] in onStart() }
    }
}

/// 开合期间固定 NSPanel 的透明画布，只由 Core Animation 合成。诊断采样器默认关闭，
/// 即使主线程暂时忙碌，合成器仍可继续当前的变换与透明度过渡。
@MainActor
final class PopupPresentation {
    private weak var panel: NSPanel?
    private weak var surface: PopupSurfaceView?
    private let kind: String
    private let onLayout: () -> Void
    private var targetFrame = CGRect.zero
    private var geometry: PopupMorphGeometry?
    private var usesExpandedCanvas = false
    private var preparedFromSource = false
    private var anchor = CGRect.zero
    private var position = DockPosition.bottom
    private var targetProgress: CGFloat = 0
    private var wantsVisible = false
    private var generation = 0
    private var onHidden: (() -> Void)?
    private var diagnosticTimer: Timer?
    private var trace: PopupTransitionTrace?
    private var resizeTimer: Timer?
    private var resizeState: (from: CGRect, to: CGRect, canvas: CGRect, started: TimeInterval, duration: TimeInterval, token: Int)?

    init(panel: NSPanel, surface: PopupSurfaceView, kind: String, onLayout: @escaping () -> Void = {}) {
        self.panel = panel; self.surface = surface; self.kind = kind; self.onLayout = onLayout
        panel.animationBehavior = .none
    }

    /// 外框：面板主体朝入口一侧多出箭头那一条（主体离入口 12 点，箭尖离入口约 2 点）。
    private func outerFrame(for body: CGRect) -> CGRect {
        let depth = PopupSurfaceView.arrowSize.height
        switch position {
        case .bottom: return CGRect(x: body.minX, y: body.minY - depth, width: body.width, height: body.height + depth)
        case .left: return CGRect(x: body.minX - depth, y: body.minY, width: body.width + depth, height: body.height)
        case .right: return CGRect(x: body.minX, y: body.minY, width: body.width + depth, height: body.height)
        }
    }

    /// 展开、收起的起点：箭尖处的一个小点（与系统弹出框一样从箭尖长出、缩回箭尖）。
    /// 箭头横向位置与 PopupSurfaceView.outline 一致：跟着入口中心，但不进圆角范围。
    private func arrowTip(of frame: CGRect) -> CGRect {
        let inset = 24 + PopupSurfaceView.arrowSize.width / 2
        let point: CGPoint
        switch position {
        case .bottom: point = CGPoint(x: min(max(anchor.midX, frame.minX + inset), frame.maxX - inset), y: frame.minY)
        case .left: point = CGPoint(x: frame.minX, y: min(max(anchor.midY, frame.minY + inset), frame.maxY - inset))
        case .right: point = CGPoint(x: frame.maxX, y: min(max(anchor.midY, frame.minY + inset), frame.maxY - inset))
        }
        return CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
    }

    /// 箭尖对准入口中心，换算到窗口坐标。
    private func arrow(inWindow window: CGRect) -> PopupSurfaceView.Arrow {
        PopupSurfaceView.Arrow(edge: position, tip: CGPoint(x: anchor.midX - window.minX, y: anchor.midY - window.minY))
    }

    func setLayout(frame body: CGRect, anchor: CGRect, position: DockPosition, animated: Bool = true) {
        self.anchor = anchor; self.position = position
        let frame = outerFrame(for: body)
        guard let panel, let surface,
              let next = PopupMorphGeometry(sourceFrame: arrowTip(of: frame), targetFrame: frame,
                  backingScale: panel.backingScaleFactor)
                ?? PopupMorphGeometry(sourceFrame: frame, targetFrame: frame,
                    backingScale: panel.backingScaleFactor) else { return }
        let changed = geometry != next
        targetFrame = frame
        geometry = next
        if !panel.isVisible {
            preparedFromSource = true
            applyCanvas(expanded: !reduceMotion)
            surface.setPresentation(transform: reduceMotion ? .identity : next.transform(at: 0),
                                    opacity: 0, duration: 0)
        } else if changed, wantsVisible {
            // 内容或入口变动只重新拟合一次；正常开合不经过这条布局路径。
            trace?.layoutRetargets += 1
            finishTrace(reason: "layout-retarget", interrupted: true)
            generation &+= 1
            surface.setPresentation(transform: .identity, opacity: 1, duration: 0)
            applyCanvas(expanded: false)
            targetProgress = 1
            preparedFromSource = false
        } else if changed {
            // 正在收起时改开另一组，旧事务不能继续使用新组的几何或关闭新面板。
            finishTrace(reason: "closing-layout-switch", interrupted: true)
            generation &+= 1
            applyCanvas(expanded: !reduceMotion)
            surface.setPresentation(transform: reduceMotion ? .identity : next.transform(at: 0),
                                    opacity: 0, duration: 0)
            targetProgress = 0
            preparedFromSource = true
            // 只有紧接着 present() 才是“改开另一组”；否则立即收起，不留下来源大小的残影。
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !self.wantsVisible else { return }
                self.panel?.orderOut(nil)
                let finished = self.onHidden; self.onHidden = nil; finished?()
            }
        }
    }

    /// 展开状态下改尺寸（拖入时加行、拖离时收回）：外壳从旧尺寸平滑过渡到新尺寸，不一步跳过去。
    /// 窗口先扩到新旧并集，逐帧调整内容框，结束后收紧到新尺寸。开合动画进行中时退回普通布局。
    func resizeVisible(to body: CGRect, anchor: CGRect, position: DockPosition) {
        self.position = position
        let frame = outerFrame(for: body)
        guard let panel, let surface, panel.isVisible, wantsVisible, targetProgress == 1, !usesExpandedCanvas,
              let current = geometry?.targetFrame, current != frame,
              let next = PopupMorphGeometry(sourceFrame: arrowTip(of: frame), targetFrame: frame, backingScale: panel.backingScaleFactor) else {
            setLayout(frame: body, anchor: anchor, position: position)
            return
        }
        resizeTimer?.invalidate()
        self.anchor = anchor; self.position = position
        let from = surface.contentFrameInScreen(of: panel) ?? current
        let canvas = from.union(frame)
        targetFrame = frame
        geometry = next
        panel.hasShadow = false
        if panel.frame != canvas { panel.setFrame(canvas, display: false) }
        surface.configureContent(frame: from.offsetBy(dx: -canvas.minX, dy: -canvas.minY), expandedCanvas: true, arrow: arrow(inWindow: canvas))
        surface.layoutSubtreeIfNeeded()
        resizeState = (from, frame, canvas, ProcessInfo.processInfo.systemUptime, reduceMotion ? 0 : 0.26, generation)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.stepResize() } }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    private func stepResize() {
        guard let state = resizeState, let surface, generation == state.token, wantsVisible else {
            resizeTimer?.invalidate(); resizeTimer = nil; resizeState = nil
            return
        }
        let t = state.duration == 0 ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - state.started) / state.duration)
        let eased = CGFloat(1 - pow(1 - t, 3))
        let from = state.from, to = state.to
        let rect = CGRect(x: from.minX + (to.minX - from.minX) * eased, y: from.minY + (to.minY - from.minY) * eased,
                          width: from.width + (to.width - from.width) * eased, height: from.height + (to.height - from.height) * eased)
        surface.configureContent(frame: rect.offsetBy(dx: -state.canvas.minX, dy: -state.canvas.minY), expandedCanvas: true,
                                 arrow: arrow(inWindow: state.canvas))
        surface.layoutSubtreeIfNeeded()
        guard t >= 1 else { return }
        resizeTimer?.invalidate(); resizeTimer = nil; resizeState = nil
        applyCanvas(expanded: false)
    }

    private func applyCanvas(expanded: Bool) {
        guard let panel, let surface, let geometry else { return }
        let windowFrame = expanded ? geometry.canvasFrame : geometry.targetFrame
        let contentRect = geometry.targetFrame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        let previousContentSize = surface.content.bounds.size
        usesExpandedCanvas = expanded
        if panel.hasShadow == expanded { panel.hasShadow = !expanded }
        if panel.frame != windowFrame { panel.setFrame(windowFrame, display: false) }
        surface.configureContent(frame: contentRect, expandedCanvas: expanded, arrow: arrow(inWindow: windowFrame))
        surface.layoutSubtreeIfNeeded()
        if previousContentSize != surface.content.bounds.size { onLayout() }
        if !expanded { panel.invalidateShadow() }
    }

    func present() {
        guard let panel, let surface, let geometry else { return }
        finishTrace(reason: "present-retarget", interrupted: true)
        let coldOpen = preparedFromSource || !panel.isVisible || wantsVisible
        if coldOpen {
            applyCanvas(expanded: !reduceMotion)
            surface.setPresentation(transform: reduceMotion ? .identity : geometry.transform(at: 0),
                                    opacity: 0, duration: 0)
        }
        onHidden = nil; wantsVisible = true
        panel.ignoresMouseEvents = false
        // 首次上屏时 AppKit 会在第一次显示时重置层基点；先以 alpha 0 完成这次显示/排版，
        // 再在 transition 里固定基点和起始变换后显示，避免动画前闪一帧从左展开的画布。
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        preparedFromSource = false
        transition(to: 1, animated: true, action: "open", coldOpen: coldOpen)
    }

    func dismiss(animated: Bool = true, onHidden: @escaping () -> Void) {
        finishTrace(reason: "dismiss-retarget", interrupted: true)
        wantsVisible = false; self.onHidden = onHidden
        if animated, !reduceMotion { applyCanvas(expanded: true) }
        panel?.ignoresMouseEvents = true
        transition(to: 0, animated: animated, action: "close")
    }

    /// 开合动画期间窗口扩成连着入口图标的画布，整块都接收点击；落在面板内容之外的点击返回其屏幕位置，
    /// 由调用方按“点到了下面”处理（例如再次点入口收起），否则这一下会被透明画布吞掉。
    func canvasClickOutsideContent(_ event: NSEvent) -> CGPoint? {
        guard usesExpandedCanvas, let panel, let surface, event.window === panel,
              let content = surface.contentFrameInScreen(of: panel) else { return nil }
        let point = panel.convertPoint(toScreen: event.locationInWindow)
        return content.contains(point) ? nil : point
    }

    /// 操作开始后直接落在最终坐标，拖动和右键菜单不依赖动画中的显示位置。
    func finishOpeningForInteraction() {
        guard wantsVisible else { return }
        finishTrace(reason: "interaction-settle", interrupted: true)
        transition(to: 1, animated: false, action: "interaction", deferCanvasTightening: true)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func transition(to target: CGFloat, animated: Bool, action: String,
                            deferCanvasTightening: Bool = false, coldOpen: Bool = false) {
        guard let surface, let geometry else { return }
        generation &+= 1
        let token = generation
        let observed = surface.sampledPresentation
        let startTransform = geometry.startingTransform(coldOpen: coldOpen && !reduceMotion, current: observed.transform)
        let startOpacity: CGFloat = coldOpen && !reduceMotion ? 0 : observed.opacity
        let current = geometry.progress(of: startTransform)
        targetProgress = target
        let duration = animated && !reduceMotion ? (target == 1 ? 0.24 : 0.17) * Double(abs(target - current)) : 0
        if PopupTransitionRecorder.isEnabled {
            trace = PopupTransitionTrace(kind: kind, action: action, source: "core-animation", position: position.rawValue,
                anchor: anchor, targetFrame: targetFrame, canvasFrame: geometry.canvasFrame,
                reduceMotion: reduceMotion, requestedDuration: duration,
                requestedFromFrame: geometry.mappedFrame(using: startTransform), coldOpen: coldOpen)
            recordPresentationSample()
        }
        surface.setPresentation(transform: reduceMotion ? .identity : geometry.transform(at: target),
                                opacity: Float(target), duration: duration,
                                fromTransform: startTransform, fromOpacity: startOpacity,
                                onCompletion: { [weak self] in
                                    self?.settled(token: token,
                                        completionSource: duration > 0 ? "ca-transaction-complete" : "immediate",
                                        deferCanvasTightening: deferCanvasTightening)
                                })
        // 起始基点和变换已经落到层上，再让窗口参与显示；首次开合不会先露旧画布。
        if wantsVisible, let panel, panel.alphaValue != 1 { panel.alphaValue = 1 }
        if duration > 0, trace != nil { startDiagnosticSampling() }
    }

    private func settled(token: Int, completionSource: String, deferCanvasTightening: Bool) {
        guard token == generation else { return }
        // 这是 CA 事务完成确认，不代表屏幕最终一帧的光学/逐帧采集证明。
        recordPresentationSample()
        finishTrace(reason: completionSource, interrupted: false)
        if wantsVisible, targetProgress == 1 {
            if deferCanvasTightening, usesExpandedCanvas {
                // 当前 mouseDown 的 locationInWindow 属于旧画布，先派发再收紧，避免首击坐标跳变。
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.wantsVisible else { return }
                    self.applyCanvas(expanded: false)
                }
            } else { applyCanvas(expanded: false) }
            return
        }
        guard !wantsVisible, targetProgress == 0 else { return }
        panel?.orderOut(nil)
        let finished = onHidden; onHidden = nil; finished?()
    }

    private func startDiagnosticSampling() {
        guard diagnosticTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordPresentationSample() }
        }
        diagnosticTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func recordPresentationSample() {
        guard trace != nil, let surface, let panel, let geometry else { return }
        let sampled = surface.sampledPresentation
        guard sampled.sampleKind == "presentation" else {
            trace?.noteUnpresented(kind: sampled.sampleKind)
            return
        }
        trace?.append(progress: geometry.progress(of: sampled.transform), scale: sampled.transform.a, alpha: sampled.opacity,
                      frame: panel.frame, mappedFrame: geometry.mappedFrame(using: sampled.transform),
                      transform: sampled.transform, at: ProcessInfo.processInfo.systemUptime)
    }

    private func finishTrace(reason: String, interrupted: Bool) {
        diagnosticTimer?.invalidate(); diagnosticTimer = nil
        guard var trace else { return }
        self.trace = nil
        if interrupted { trace.interruptionReason = reason }
        PopupTransitionRecorder.append(trace.record(finishedAt: ProcessInfo.processInfo.systemUptime, completion: reason))
    }
}

/// 只收集本面板的数值；不保存窗口标题、分组名称、文件名或截图。
private struct PopupTransitionTrace {
    let kind: String
    let action: String
    let source: String
    let position: String
    let anchor: CGRect
    let targetFrame: CGRect
    let canvasFrame: CGRect
    let reduceMotion: Bool
    let requestedDuration: TimeInterval
    let requestedFromFrame: CGRect
    let coldOpen: Bool
    let startedAt = ProcessInfo.processInfo.systemUptime
    var interruptionReason: String?
    var layoutRetargets = 0
    private var samples: [[String: Any]] = []
    private var sampleCount = 0
    private var firstPresentationTime: TimeInterval?
    private var intermediateFrames = 0
    private var progressRange = [Double.infinity, -Double.infinity]
    private var scaleRange = [Double.infinity, -Double.infinity]
    private var alphaRange = [Double.infinity, -Double.infinity]
    private var frameRange = Array(repeating: [Double.infinity, -Double.infinity], count: 4)
    private var previousSampleTime: TimeInterval?
    private var sampleGaps: [Double] = []
    private var omittedUnpresentedSamples: [String: Int] = [:]

    init(kind: String, action: String, source: String, position: String, anchor: CGRect,
         targetFrame: CGRect, canvasFrame: CGRect, reduceMotion: Bool, requestedDuration: TimeInterval,
         requestedFromFrame: CGRect, coldOpen: Bool) {
        self.kind = kind == "files" ? "files" : "group"
        self.action = action; self.source = source; self.position = position
        self.anchor = anchor; self.targetFrame = targetFrame; self.canvasFrame = canvasFrame; self.reduceMotion = reduceMotion
        self.requestedDuration = requestedDuration
        self.requestedFromFrame = requestedFromFrame; self.coldOpen = coldOpen
    }

    mutating func noteUnpresented(kind: String) { omittedUnpresentedSamples[kind, default: 0] += 1 }

    mutating func append(progress: CGFloat, scale: CGFloat, alpha: CGFloat, frame: CGRect,
                         mappedFrame: CGRect, transform: CGAffineTransform, at now: TimeInterval) {
        let values = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
        sampleCount += 1
        if firstPresentationTime == nil { firstPresentationTime = now }
        if let previousSampleTime, now > previousSampleTime, sampleGaps.count < 80 {
            sampleGaps.append((now - previousSampleTime) * 1_000)
        }
        previousSampleTime = now
        if progress > 0.000_001 && progress < 0.999_999 { intermediateFrames += 1 }
        expand(&progressRange, Double(progress)); expand(&scaleRange, Double(scale)); expand(&alphaRange, Double(alpha))
        for index in values.indices { expand(&frameRange[index], values[index]) }
        let sample: [String: Any] = ["elapsedMs": max(0, (now - startedAt) * 1000),
                                      "progress": Double(progress), "scale": Double(scale),
                                      "alpha": Double(alpha), "frame": values,
                                      "mappedContentFrame": rect(mappedFrame),
                                      "transform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
                                      "sampleKind": "presentation"]
        if samples.count < 80 { samples.append(sample) }
        else { samples[79] = sample }
    }

    func record(finishedAt: TimeInterval, completion: String) -> [String: Any] {
        ["kind": kind, "action": action, "source": source, "position": position,
         "reduceMotion": reduceMotion, "interrupted": interruptionReason != nil,
         "interruptionReason": interruptionReason as Any? ?? NSNull(), "completion": completion,
         "startedAtUptime": startedAt, "durationMs": max(0, (finishedAt - startedAt) * 1000),
         "requestedDurationMs": requestedDuration * 1000,
         "coldOpen": coldOpen, "requestedFromFrame": rect(requestedFromFrame),
         "omittedUnpresentedSamples": omittedUnpresentedSamples,
         "firstPresentationLatencyMs": firstPresentationTime.map { max(0, ($0 - startedAt) * 1_000) } as Any? ?? NSNull(),
         "presentationSamples": sampleCount, "intermediateSamples": intermediateFrames,
         "mainThreadSampleGapMaxMs": sampleGaps.max() ?? 0,
         "mainThreadSampleGapP95Ms": sampleGaps.sorted().dropFirst(Int(Double(max(0, sampleGaps.count - 1)) * 0.95)).first ?? 0,
         "progressMinMax": finite(progressRange), "scaleMinMax": finite(scaleRange), "alphaMinMax": finite(alphaRange),
         "frameMinMaxXYWH": frameRange.map(finite), "anchorFrame": rect(anchor), "initialTargetFrame": rect(targetFrame),
         "canvasFrame": rect(canvasFrame), "geometry": "目标 layer 中心为 anchorPoint；transform 把目标四角映射到来源四角",
         "layoutRetargets": layoutRetargets, "samples": samples]
    }

    private func expand(_ range: inout [Double], _ value: Double) {
        range[0] = min(range[0], value); range[1] = max(range[1], value)
    }
    private func finite(_ range: [Double]) -> [Double] { range.map { $0.isFinite ? $0 : 0 } }
    private func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
}

@MainActor
private enum PopupTransitionRecorder {
    private static var records: [[String: Any]] = []
    private static let sessionID = UUID().uuidString

    private static var diagnosticsDirectory: URL? { AppDataLocation.diagnosticsDirectory }

    static var isEnabled: Bool {
        guard let diagnosticsDirectory else { return false }
        return ProcessInfo.processInfo.environment["DOCKFOLDERS_POPUP_DIAGNOSTICS"] == "1"
            || FileManager.default.fileExists(atPath: diagnosticsDirectory.appendingPathComponent("0.4-popup-transitions.enabled").path)
    }

    static func append(_ record: [String: Any]) {
        guard let diagnosticsDirectory else { return }
        records.append(record)
        if records.count > 20 { records.removeFirst(records.count - 20) }
        let output: [String: Any] = ["schemaVersion": 2, "sessionID": sessionID,
                                      "processID": ProcessInfo.processInfo.processIdentifier,
                                      "measurement": "仅记录 animationDidStart 之后的 Core Animation presentation layer；pending/model-only 被计数但不作已呈现样本；不等同屏幕逐帧呈现确认",
                                      "records": records]
        // 一次完成或反向才写一次，渲染循环只更新内存中的有限样本。
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: diagnosticsDirectory.appendingPathComponent("0.4-popup-transitions.json"), options: .atomic)
    }
}
