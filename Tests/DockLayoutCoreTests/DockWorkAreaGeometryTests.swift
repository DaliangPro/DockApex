import CoreGraphics
import Testing
@testable import DockLayoutCore

private let workScreen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
private let workUsable = CGRect(x: 0, y: 0, width: 1600, height: 970)
private func workZone(_ position: DockPosition = .bottom) -> DockWorkAreaZone {
    let reserved: CGRect
    switch position {
    case .bottom: reserved = CGRect(x: 0, y: 0, width: 1600, height: 60)
    case .left: reserved = CGRect(x: 0, y: 0, width: 60, height: 1000)
    case .right: reserved = CGRect(x: 1540, y: 0, width: 60, height: 1000)
    }
    return DockWorkAreaZone(displayUUID: "主屏", screenFrame: workScreen, usableFrame: workUsable, reservedFrame: reserved, position: position)
}

@Test func `隐藏系统Dock残留57pt占位不会阻止内屏避让`() {
    let screen = CGRect(x: 1012, y: -1329, width: 2056, height: 1329)
    let staleNativeVisible = CGRect(x: 1012, y: -1272, width: 2056, height: 1233)
    let normalized = DockWorkAreaGeometry.normalizedUsableFrame(screenFrame: screen, reportedVisibleFrame: staleNativeVisible)
    #expect(normalized == CGRect(x: 1012, y: -1329, width: 2056, height: 1290))
    let zone = DockWorkAreaZone(displayUUID: "内屏", screenFrame: screen, usableFrame: normalized,
                               reservedFrame: CGRect(x: 1012, y: -1329, width: 2056, height: 60), position: .bottom)
    let filled = CGRect(x: 1012, y: -1329, width: 2056, height: 1290)
    #expect(DockWorkAreaGeometry.adjustedFrame(filled, zones: [zone])?.frame == CGRect(x: 1012, y: -1269, width: 2056, height: 1230))
}

@Test func `归一化去掉原生侧栏占位并保留菜单顶沿`() {
    let staleSide = CGRect(x: 57, y: 0, width: 1543, height: 970)
    #expect(DockWorkAreaGeometry.normalizedUsableFrame(screenFrame: workScreen, reportedVisibleFrame: staleSide) == workUsable)
}

@Test func `系统收回旧57pt底部占位后只补让3pt`() {
    let screen = CGRect(x: 1012, y: -1329, width: 2056, height: 1329)
    let usable = CGRect(x: 1012, y: -1329, width: 2056, height: 1290)
    let zone = DockWorkAreaZone(displayUUID: "内屏", screenFrame: screen, usableFrame: usable,
                               reservedFrame: CGRect(x: 1012, y: -1329, width: 2056, height: 60), position: .bottom)
    let nativeAdjusted = CGRect(x: 1012, y: -1272, width: 2056, height: 1233)
    let expected = CGRect(x: 1012, y: -1269, width: 2056, height: 1230)
    #expect(DockWorkAreaGeometry.adjustedFrame(nativeAdjusted, zones: [zone])?.frame == expected)
    #expect(DockWorkAreaGeometry.adjustedFrame(expected, zones: [zone]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 1200, y: -1272, width: 600, height: 500), zones: [zone]) == nil)
}

@Test func `左右旧原生57pt占位只补足差额且不会再次收窄`() {
    let left = CGRect(x: 57, y: 0, width: 1543, height: 970)
    let right = CGRect(x: 0, y: 0, width: 1543, height: 970)
    let leftExpected = CGRect(x: 60, y: 0, width: 1540, height: 970)
    let rightExpected = CGRect(x: 0, y: 0, width: 1540, height: 970)
    #expect(DockWorkAreaGeometry.adjustedFrame(left, zones: [workZone(.left)])?.frame == leftExpected)
    #expect(DockWorkAreaGeometry.adjustedFrame(right, zones: [workZone(.right)])?.frame == rightExpected)
    #expect(DockWorkAreaGeometry.adjustedFrame(leftExpected, zones: [workZone(.left)]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(rightExpected, zones: [workZone(.right)]) == nil)
}

@Test func `填充窗口底部让出基础条高度并保持顶部`() {
    #expect(DockWorkAreaGeometry.adjustedFrame(workUsable, zones: [workZone()])?.frame == CGRect(x: 0, y: 60, width: 1600, height: 910))
}

@Test func `全高半屏分栏和四分屏可以避让`() {
    let half = CGRect(x: 800, y: 0, width: 800, height: 970)
    let quarter = CGRect(x: 800, y: 0, width: 800, height: 485)
    #expect(DockWorkAreaGeometry.adjustedFrame(half, zones: [workZone()])?.frame == CGRect(x: 800, y: 60, width: 800, height: 910))
    #expect(DockWorkAreaGeometry.adjustedFrame(quarter, zones: [workZone()])?.frame == CGRect(x: 800, y: 60, width: 800, height: 425))
}

@Test func `系统平铺原有外边距保留在应用栏之外`() {
    let tiledWithMargin = CGRect(x: 808, y: 8, width: 784, height: 954)
    #expect(DockWorkAreaGeometry.adjustedFrame(tiledWithMargin, zones: [workZone()])?.frame == CGRect(x: 808, y: 68, width: 784, height: 894))
}

@Test func `普通小窗碰到底边也不移动`() {
    #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 220, y: 0, width: 600, height: 500), zones: [workZone()]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 100, y: 30, width: 1400, height: 800), zones: [workZone()]) == nil)
}

@Test func `左右停靠仅收窄侵入侧并保留另一侧边缘`() {
    #expect(DockWorkAreaGeometry.adjustedFrame(workUsable, zones: [workZone(.left)])?.frame == CGRect(x: 60, y: 0, width: 1540, height: 970))
    #expect(DockWorkAreaGeometry.adjustedFrame(workUsable, zones: [workZone(.right)])?.frame == CGRect(x: 0, y: 0, width: 1540, height: 970))
}

@Test func `只影响有应用栏的对应屏幕`() {
    let second = CGRect(x: 1600, y: -900, width: 1400, height: 900)
    let secondZone = DockWorkAreaZone(displayUUID: "扩展屏", screenFrame: second, usableFrame: second,
                                      reservedFrame: CGRect(x: 1600, y: -900, width: 1400, height: 60), position: .bottom)
    #expect(DockWorkAreaGeometry.adjustedFrame(workUsable, zones: [secondZone]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(second, zones: [workZone(), secondZone])?.frame == CGRect(x: 1600, y: -840, width: 1400, height: 840))
}

@Test func `跨屏大窗和已避让窗口不会再次缩小`() {
    #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 0, y: 0, width: 2100, height: 970), zones: [workZone()]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 0, y: 60, width: 1600, height: 910), zones: [workZone()]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(workUsable, zones: []) == nil)
}

@Test func `停止时只条件恢复仍等于本工具结果的窗口`() {
    let applied = CGRect(x: 0, y: 60, width: 1600, height: 910)
    #expect(DockWorkAreaGeometry.restoreFrame(original: workUsable, lastApplied: applied, current: applied) == workUsable)
    let changed = CGRect(x: 100, y: 80, width: 1300, height: 800)
    #expect(DockWorkAreaGeometry.restoreFrame(original: workUsable, lastApplied: applied, current: changed) == nil)
}

@Test func `三边已有系统占位的半屏四分屏和填充窗口均不重复缩小`() {
    for (position, frames) in [
        (DockPosition.bottom, [CGRect(x: 0, y: 60, width: 1600, height: 910),
                               CGRect(x: 800, y: 60, width: 800, height: 910),
                               CGRect(x: 800, y: 60, width: 800, height: 455)]),
        (.left, [CGRect(x: 60, y: 0, width: 1540, height: 970),
                 CGRect(x: 60, y: 0, width: 770, height: 970),
                 CGRect(x: 60, y: 485, width: 770, height: 485)]),
        (.right, [CGRect(x: 0, y: 0, width: 1540, height: 970),
                  CGRect(x: 770, y: 0, width: 770, height: 970),
                  CGRect(x: 770, y: 485, width: 770, height: 485)])
    ] {
        var zone = workZone(position)
        zone.reportedVisibleFrame = frames[0]
        for frame in frames { #expect(DockWorkAreaGeometry.adjustedFrame(frame, zones: [zone]) == nil) }
    }
}

@Test func `旧系统占位内的半屏和四分屏只补足新Dock差额`() {
    var zone = workZone()
    zone.reportedVisibleFrame = CGRect(x: 0, y: 57, width: 1600, height: 913)
    let half = CGRect(x: 800, y: 57, width: 800, height: 913)
    let quarter = CGRect(x: 800, y: 57, width: 800, height: 456.5)
    #expect(DockWorkAreaGeometry.adjustedFrame(half, zones: [zone])?.frame == CGRect(x: 800, y: 60, width: 800, height: 910))
    #expect(DockWorkAreaGeometry.adjustedFrame(quarter, zones: [zone])?.frame == CGRect(x: 800, y: 60, width: 800, height: 453.5))
    #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 220, y: 57, width: 600, height: 500), zones: [zone]) == nil)
}

@Test func `过大的旧区域和越界区域不充当平铺识别依据`() {
    var zone = workZone()
    for previous in [CGRect(x: 0, y: 100, width: 1600, height: 870),
                     CGRect(x: -20, y: 57, width: 1620, height: 913)] {
        zone.reportedVisibleFrame = previous
        #expect(DockWorkAreaGeometry.adjustedFrame(CGRect(x: 800, y: 57, width: 800, height: 913), zones: [zone]) == nil)
    }
}

@Test func `左右旧占位四分屏只补足差额`() {
    var left = workZone(.left)
    left.reportedVisibleFrame = CGRect(x: 57, y: 0, width: 1543, height: 970)
    let leftQuarter = CGRect(x: 57, y: 0, width: 771.5, height: 485)
    #expect(DockWorkAreaGeometry.adjustedFrame(leftQuarter, zones: [left])?.frame == CGRect(x: 60, y: 0, width: 768.5, height: 485))
    var right = workZone(.right)
    right.reportedVisibleFrame = CGRect(x: 0, y: 0, width: 1543, height: 970)
    let rightQuarter = CGRect(x: 771.5, y: 0, width: 771.5, height: 485)
    #expect(DockWorkAreaGeometry.adjustedFrame(rightQuarter, zones: [right])?.frame == CGRect(x: 771.5, y: 0, width: 768.5, height: 485))
}

@Test func `实机外屏底部57pt避让保留原3008或1504宽度`() {
    let screen = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let usable = CGRect(x: 0, y: 0, width: 3008, height: 1662)
    let zone = DockWorkAreaZone(displayUUID: "外屏", screenFrame: screen, usableFrame: usable,
                               reservedFrame: CGRect(x: 0, y: 0, width: 3008, height: 57), position: .bottom,
                               reportedVisibleFrame: usable)
    for width: CGFloat in [3008, 1504] {
        let original = CGRect(x: 0, y: 0, width: width, height: 1662)
        let expected = CGRect(x: 0, y: 57, width: width, height: 1605)
        #expect(DockWorkAreaGeometry.adjustedFrame(original, zones: [zone])?.frame == expected)
        #expect(DockWorkAreaGeometry.adjustedFrame(expected, zones: [zone]) == nil)
    }
}

/// 实测抖音：LG 左半屏大小，但整体下移 29 点，底边伸进 57 点占位一半。
private let lgScreen = CGRect(x: 0, y: 0, width: 3008, height: 1692)
private let lgZone = DockWorkAreaZone(displayUUID: "LG", screenFrame: lgScreen, usableFrame: CGRect(x: 0, y: 57, width: 3008, height: 1605),
                                      reservedFrame: CGRect(x: 0, y: 0, width: 3008, height: 57), position: .bottom)

@Test func `伸进应用栏的大窗口上方有空间时整体上移`() {
    let douyin = CGRect(x: 0, y: 29, width: 1504, height: 1604)
    #expect(DockWorkAreaGeometry.adjustedFrame(douyin, zones: [lgZone]) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(douyin, zones: [lgZone], allowIntruding: true)?.frame
            == CGRect(x: 0, y: 57, width: 1504, height: 1604))
}

@Test func `伸进应用栏的大窗口上方没空间时收短底边`() {
    let tall = CGRect(x: 200, y: 20, width: 1200, height: 1630)
    #expect(DockWorkAreaGeometry.adjustedFrame(tall, zones: [lgZone], allowIntruding: true)?.frame
            == CGRect(x: 200, y: 57, width: 1200, height: 1593))
}

@Test func `小窗口或拖到屏外的窗口不按伸进处理`() {
    let small = CGRect(x: 400, y: 20, width: 800, height: 600)
    let belowScreen = CGRect(x: 0, y: -200, width: 1504, height: 1604)
    let aboveUsable = CGRect(x: 0, y: 40, width: 1504, height: 1640)
    #expect(DockWorkAreaGeometry.adjustedFrame(small, zones: [lgZone], allowIntruding: true) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(belowScreen, zones: [lgZone], allowIntruding: true) == nil)
    #expect(DockWorkAreaGeometry.adjustedFrame(aboveUsable, zones: [lgZone], allowIntruding: true) == nil)
}

@Test func `侧边应用栏的大窗口伸进时向另一侧挪开`() {
    let left = CGRect(x: 30, y: 100, width: 800, height: 800)
    #expect(DockWorkAreaGeometry.adjustedFrame(left, zones: [workZone(.left)], allowIntruding: true)?.frame
            == CGRect(x: 60, y: 100, width: 800, height: 800))
    let right = CGRect(x: 770, y: 100, width: 800, height: 800)
    #expect(DockWorkAreaGeometry.adjustedFrame(right, zones: [workZone(.right)], allowIntruding: true)?.frame
            == CGRect(x: 740, y: 100, width: 800, height: 800))
}

@Test func `悬浮条按占位厚度上移并保留原间距`() {
    // 已运行的 App 以为底部没有 Dock，把语音条摆在离底 19 点；原生 Dock 下它在 57 + 19 = 76。
    let hud = CGRect(x: 1300, y: 19, width: 400, height: 44)
    #expect(DockWorkAreaGeometry.floatingAdjustment(hud, zones: [lgZone]) == CGPoint(x: 1300, y: 76))
    // 有一截伸到屏幕外：至少挪到占位上沿。
    #expect(DockWorkAreaGeometry.floatingAdjustment(CGRect(x: 1300, y: -10, width: 400, height: 44), zones: [lgZone])
            == CGPoint(x: 1300, y: 57))
}

@Test func `没伸进应用栏或太高的窗口不按悬浮条处理`() {
    #expect(DockWorkAreaGeometry.floatingAdjustment(CGRect(x: 1300, y: 60, width: 400, height: 44), zones: [lgZone]) == nil)
    #expect(DockWorkAreaGeometry.floatingAdjustment(CGRect(x: 0, y: 29, width: 1504, height: 1604), zones: [lgZone]) == nil)
}

@Test func `侧边应用栏的悬浮条向屏内挪开`() {
    #expect(DockWorkAreaGeometry.floatingAdjustment(CGRect(x: 10, y: 400, width: 200, height: 80), zones: [workZone(.left)])
            == CGPoint(x: 70, y: 400))
    #expect(DockWorkAreaGeometry.floatingAdjustment(CGRect(x: 1390, y: 400, width: 200, height: 80), zones: [workZone(.right)])
            == CGPoint(x: 1330, y: 400))
}

@Test func `重试只按还在将来的时刻调度，过期没轮到的不再空转`() {
    #expect(DockWorkAreaGeometry.nextRetry([], now: 10) == nil)
    #expect(DockWorkAreaGeometry.nextRetry([9, 9.5], now: 10) == nil)
    #expect(DockWorkAreaGeometry.nextRetry([9, 11, 10.5], now: 10) == 10.5)
}
