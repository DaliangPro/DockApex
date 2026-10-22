import Foundation
import Testing
@testable import DockLayoutCore

@Test func `另一屏幕上的全屏不会因前台应用切换而失效`() {
    let displays: [DockFullscreenGeometry.Display] = [
        .init(id: 1, frame: CGRect(x: 0, y: 0, width: 3008, height: 1692)),
        .init(id: 2, frame: CGRect(x: -1728, y: 200, width: 1728, height: 1117))
    ]
    let windows: [DockFullscreenGeometry.Window] = [.init(frame: displays[1].frame, isFullscreen: true),
        .init(frame: CGRect(x: 500, y: 100, width: 900, height: 700), isFullscreen: false)]
    #expect(DockFullscreenGeometry.coveredDisplays(windows: windows, displays: displays) == [2])
    #expect(DockFullscreenGeometry.coveredDisplays(windows: displays.map { .init(frame: $0.frame, isFullscreen: true) }, displays: displays) == [1, 2])
}

@Test func `铺满可用区域的普通窗口不当作全屏`() {
    let screen = DockFullscreenGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: CGRect(x: 0, y: 25, width: 1728, height: 1035), isFullscreen: false)], displays: [screen]).isEmpty)
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [], displays: [screen]).isEmpty)
}

@Test func `屏幕拔出或移动后不沿用旧全屏范围`() {
    let old = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: old, isFullscreen: true)], displays: []).isEmpty)
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: old, isFullscreen: true)], displays: [.init(id: 1, frame: old.offsetBy(dx: 1728, dy: 0))]).isEmpty)
}

@Test func `刘海安全区内的真实全屏被正确识别`() {
    let display = DockFullscreenGeometry.Display(id: 1,
        frame: CGRect(x: 1012, y: 1692, width: 2056, height: 1329),
        safeFrame: CGRect(x: 1012, y: 1731, width: 2056, height: 1290))
    #expect(DockFullscreenGeometry.candidateDisplays(window: display.safeFrame, displays: [display]) == [1])
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: display.safeFrame, isFullscreen: true)], displays: [display]) == [1])
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: display.frame, isFullscreen: true)], displays: [display]) == [1])
}

@Test func `与全屏或刘海安全区完全同尺寸的普通窗口仍不触发全屏`() {
    let display = DockFullscreenGeometry.Display(id: 1,
        frame: CGRect(x: 1012, y: 1692, width: 2056, height: 1329),
        safeFrame: CGRect(x: 1012, y: 1731, width: 2056, height: 1290))
    for frame in [display.frame, display.safeFrame] {
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: false)], displays: [display]).isEmpty)
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: nil)], displays: [display]).isEmpty)
    }
}

@Test func `硬件安全区与窗口的一点边界取整差异可匹配`() {
    let display = DockFullscreenGeometry.Display(id: 1,
        frame: CGRect(x: 1012, y: 1692, width: 2056, height: 1329),
        safeFrame: CGRect(x: 1012, y: 1730, width: 2056, height: 1291))
    let content = CGRect(x: 1012, y: 1731, width: 2056, height: 1290)
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: content, isFullscreen: true)], displays: [display]) == [1])
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: content, isFullscreen: false)], displays: [display]).isEmpty)
}

@Test func `只有全屏标志而几何不在当前显示器也不采用`() {
    let display = DockFullscreenGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2000, height: 1300),
        safeFrame: CGRect(x: 0, y: 39, width: 2000, height: 1261))
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: CGRect(x: 0, y: 39, width: 2000, height: 1204), isFullscreen: true)], displays: [display]).isEmpty)
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: display.safeFrame.offsetBy(dx: 2000, dy: 0), isFullscreen: true)], displays: [display]).isEmpty)
}

@Test func `损坏的安全区和非有限窗口坐标不会扩大候选范围`() {
    let frame = CGRect(x: 0, y: 0, width: 2000, height: 1300)
    let display = DockFullscreenGeometry.Display(id: 1, frame: frame, safeFrame: frame.offsetBy(dx: 1, dy: 0))
    #expect(DockFullscreenGeometry.candidateDisplays(window: CGRect(x: CGFloat.infinity, y: 0, width: 2000, height: 1300), displays: [display]).isEmpty)
    #expect(DockFullscreenGeometry.candidateDisplays(window: frame.offsetBy(dx: 3, dy: 0), displays: [display]).isEmpty)
}

@Test func `左右等比分屏留有分隔缝且仍按所在显示器确认`() {
    let displays: [DockFullscreenGeometry.Display] = [
        .init(id: 1, frame: CGRect(x: 0, y: 0, width: 3008, height: 1692)),
        .init(id: 2, frame: CGRect(x: -2000, y: 200, width: 2000, height: 1300))
    ]
    let left = CGRect(x: -2000, y: 200, width: 996, height: 1300)
    let right = CGRect(x: -996, y: 200, width: 996, height: 1300)
    for frame in [left, right] {
        #expect(DockFullscreenGeometry.candidateDisplays(window: frame, displays: displays) == [2])
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: true)], displays: displays) == [2])
    }
    #expect(DockFullscreenGeometry.coveredDisplays(windows: [left, right].map { .init(frame: $0, isFullscreen: true) }, displays: displays) == [2])
}

@Test func `刘海屏不等宽分屏保留一点安全区取整容差`() {
    let display = DockFullscreenGeometry.Display(id: 1,
        frame: CGRect(x: 1012, y: 1692, width: 2056, height: 1329),
        safeFrame: CGRect(x: 1012, y: 1730, width: 2056, height: 1291))
    let left = CGRect(x: 1012, y: 1731, width: 680, height: 1290)
    let right = CGRect(x: 1700, y: 1731, width: 1368, height: 1290)
    for frame in [left, right] {
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: true)], displays: [display]) == [1])
    }
}

@Test func `与原生分屏同几何的普通贴边或未知窗口不能触发全屏`() {
    let display = DockFullscreenGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2000, height: 1300))
    for frame in [CGRect(x: 0, y: 0, width: 996, height: 1300), CGRect(x: 1004, y: 0, width: 996, height: 1300)] {
        #expect(DockFullscreenGeometry.candidateDisplays(window: frame, displays: [display]) == [1])
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: false)], displays: [display]).isEmpty)
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: nil)], displays: [display]).isEmpty)
    }
}

@Test func `分屏候选拒绝窄工具条中间浮窗越界和非完整高度`() {
    let display = DockFullscreenGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2000, height: 1300))
    let invalid = [
        CGRect(x: 0, y: 0, width: 150, height: 1300),
        CGRect(x: 0, y: 0, width: 1900, height: 1300),
        CGRect(x: 400, y: 0, width: 1000, height: 1300),
        CGRect(x: -3, y: 0, width: 1000, height: 1300),
        CGRect(x: 1003, y: 0, width: 1000, height: 1300),
        CGRect(x: 0, y: 39, width: 1000, height: 1261),
        CGRect(x: 0, y: 0, width: 1000, height: 1243)
    ]
    for frame in invalid {
        #expect(DockFullscreenGeometry.candidateDisplays(window: frame, displays: [display]).isEmpty)
        #expect(DockFullscreenGeometry.coveredDisplays(windows: [.init(frame: frame, isFullscreen: true)], displays: [display]).isEmpty)
    }
}

@Test func `分屏宽度候选有界且容纳小屏不等宽窗口`() {
    let display = DockFullscreenGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    #expect(DockFullscreenGeometry.candidateDisplays(window: CGRect(x: 0, y: 0, width: 160, height: 700), displays: [display]) == [1])
    #expect(DockFullscreenGeometry.candidateDisplays(window: CGRect(x: 160, y: 0, width: 840, height: 700), displays: [display]) == [1])
    #expect(DockFullscreenGeometry.candidateDisplays(window: CGRect(x: 0, y: 0, width: 159, height: 700), displays: [display]).isEmpty)
    #expect(DockFullscreenGeometry.candidateDisplays(window: CGRect(x: 159, y: 0, width: 841, height: 700), displays: [display]).isEmpty)
}
