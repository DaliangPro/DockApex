import CoreGraphics
import Testing
@testable import DockLayoutCore

/// 1504×1605 的贴底窗口，底边在占位区上沿 57 点处。
private let window = CGRect(x: 1504, y: 57, width: 1504, height: 1605)
private let dockStrip = CGRect(x: 992, y: 0, width: 1024, height: 57)

private func alpha(_ map: (width: Int, height: Int, alpha: [UInt8]), region: CGRect, scale: Double, x: Double, y: Double) -> Double {
    let column = Int((x - Double(region.minX)) * scale)
    let row = Int((Double(region.maxY) - y) * scale)
    return Double(map.alpha[row * map.width + column]) / 255
}

@Test func `活跃窗口中段阴影与实测曲线一致`() {
    let map = WindowShadowRenderer.alphaMap(region: dockStrip, scale: 1, casters: [.init(frame: window, active: true)])
    // 实测：贴边约 0.31，向下 10 点约 0.25，30 点约 0.10，51 点约 0.016。
    #expect(abs(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 56.5) - 0.31) < 0.02)
    #expect(abs(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 46.5) - 0.25) < 0.02)
    #expect(abs(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 26.5) - 0.10) < 0.02)
    #expect(abs(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 5.5) - 0.016) < 0.01)
}

@Test func `非活跃窗口阴影浅且更早消失`() {
    let map = WindowShadowRenderer.alphaMap(region: dockStrip, scale: 1, casters: [.init(frame: window, active: false)])
    #expect(abs(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 56.5) - 0.165) < 0.02)
    #expect(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 20.5) < 0.005)
}

@Test func `窗口左右端按实测渐隐`() {
    let active = WindowShadowProfile.active
    // 实测（底下约 7 点）：窗口边缘约为中段一半，外侧 18 点约 0.18，内侧 18 点约 0.8。
    #expect(abs(active.horizontal(at: 1504, minX: 1504, maxX: 3008) - 0.5) < 0.03)
    #expect(abs(active.horizontal(at: 1486, minX: 1504, maxX: 3008) - 0.18) < 0.04)
    #expect(abs(active.horizontal(at: 1522, minX: 1504, maxX: 3008) - 0.8) < 0.05)
    let inactive = WindowShadowProfile.inactive
    // 非活跃：圆角内收，边缘处只有约三分之一，外侧 14 点基本为 0。
    #expect(inactive.horizontal(at: 1504, minX: 1504, maxX: 3008) < 0.4)
    #expect(inactive.horizontal(at: 1490, minX: 1504, maxX: 3008) < 0.05)
}

@Test func `第一行最靠近窗口底边`() {
    let map = WindowShadowRenderer.alphaMap(region: dockStrip, scale: 2, casters: [.init(frame: window, active: true)])
    #expect(map.width == 2048 && map.height == 114)
    let column = (1900 - 992) * 2
    #expect(map.alpha[column] > map.alpha[(map.height - 1) * map.width + column])
}

@Test func `前面窗口的本体挡住后面窗口的阴影`() {
    // 前窗口伸进占位区（底边 20 点），后窗口贴在占位区上沿；前窗口本体上不能有任何阴影。
    let front = WindowShadowCaster(frame: CGRect(x: 1200, y: 20, width: 400, height: 800), active: false)
    let back = WindowShadowCaster(frame: CGRect(x: 1000, y: 57, width: 1000, height: 800), active: true)
    let map = WindowShadowRenderer.alphaMap(region: dockStrip, scale: 1, casters: [front, back])
    #expect(alpha(map, region: dockStrip, scale: 1, x: 1400, y: 40.5) == 0)
    // 前窗口底边以下仍有两层阴影叠加：1 - (1 - a)(1 - b)。
    let a = WindowShadowProfile.inactive.vertical(at: 20 - 10.5) * WindowShadowProfile.inactive.horizontal(at: 1400.5, minX: 1200, maxX: 1600)
    let b = WindowShadowProfile.active.vertical(at: 57 - 10.5) * WindowShadowProfile.active.horizontal(at: 1400.5, minX: 1000, maxX: 2000)
    #expect(abs(alpha(map, region: dockStrip, scale: 1, x: 1400, y: 10.5) - (1 - (1 - a) * (1 - b))) < 0.01)
    // 前窗口旁边（本体以外）仍能看到后窗口的阴影。
    #expect(alpha(map, region: dockStrip, scale: 1, x: 1800, y: 40.5) > 0.1)
}

@Test func `远离区域的窗口不参与`() {
    let far = WindowShadowCaster(frame: CGRect(x: 1200, y: 400, width: 400, height: 400), active: true)
    let side = WindowShadowCaster(frame: CGRect(x: 0, y: 57, width: 900, height: 800), active: true)
    #expect(WindowShadowRenderer.relevant([far, side], in: dockStrip).isEmpty)
    let map = WindowShadowRenderer.alphaMap(region: dockStrip, scale: 1, casters: [far, side])
    #expect(map.alpha.allSatisfy { $0 == 0 })
}

@Test func `窗口顶边以上只有很浅的阴影`() {
    let region = CGRect(x: 1500, y: 1662, width: 400, height: 30)
    let map = WindowShadowRenderer.alphaMap(region: region, scale: 1, casters: [.init(frame: CGRect(x: 1504, y: 57, width: 1504, height: 1605), active: true)])
    // 顶边上 1 点约 0.06，远低于底边下的 0.31；29 点外基本为 0。
    #expect(abs(alpha(map, region: region, scale: 1, x: 1800, y: 1662.5) - 0.06) < 0.015)
    #expect(alpha(map, region: region, scale: 1, x: 1800, y: 1691.5) < 0.006)
}

@Test func `排除区域内不画阴影`() {
    let exclusion = CGRect(x: 1600, y: 0, width: 200, height: 57)
    let map = WindowShadowRenderer.alphaMap(region: dockStrip, scale: 1, casters: [.init(frame: window, active: true)], exclusions: [exclusion])
    #expect(alpha(map, region: dockStrip, scale: 1, x: 1700, y: 50.5) == 0)
    #expect(alpha(map, region: dockStrip, scale: 1, x: 1900, y: 50.5) > 0.2)
}
