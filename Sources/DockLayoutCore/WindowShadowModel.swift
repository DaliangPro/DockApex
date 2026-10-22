import Foundation
import CoreGraphics

/// 普通窗口投在 Dock 区域的阴影。屏幕捕捉拿不到 WindowServer 合成的窗口阴影，
/// 补底只能按实测曲线自己画回去。数据来自 macOS 27.0.1 单窗口截取（带阴影）的 alpha 测量。
struct WindowShadowProfile: Equatable, Sendable {
    /// 窗口底边以下每 1 点的阴影不透明度（中段，远离左右端）。
    var vertical: [Double]
    /// 窗口顶边以上每 1 点的阴影不透明度（阴影向下偏，顶边以上很浅）。
    var top: [Double]
    /// 左右两端：半深度点相对窗口边缘向内收的距离（圆角造成）。
    var edgeInset: Double
    /// 左右两端渐隐的宽度（高斯边缘的标准差）。
    var edgeSigma: Double

    /// 当前 App 的主窗口：阴影宽而深。
    static let active = WindowShadowProfile(vertical: [
        0.310, 0.317, 0.308, 0.299, 0.292, 0.286, 0.279, 0.273, 0.264, 0.259,
        0.251, 0.245, 0.237, 0.228, 0.220, 0.213, 0.206, 0.197, 0.188, 0.183,
        0.174, 0.164, 0.158, 0.151, 0.144, 0.135, 0.126, 0.122, 0.114, 0.109,
        0.100, 0.093, 0.088, 0.084, 0.077, 0.072, 0.067, 0.063, 0.054, 0.050,
        0.047, 0.045, 0.041, 0.036, 0.032, 0.031, 0.027, 0.024, 0.023, 0.020,
        0.018, 0.016, 0.016, 0.013, 0.012, 0.012, 0.008, 0.008, 0.008, 0.006,
        0.004, 0.004, 0.004, 0.004, 0.004, 0
    ], top: [
        0.059, 0.063, 0.058, 0.052, 0.047, 0.045, 0.040, 0.036, 0.032, 0.027,
        0.027, 0.026, 0.023, 0.020, 0.018, 0.016, 0.016, 0.013, 0.012, 0.012,
        0.008, 0.008, 0.008, 0.006, 0.004, 0.004, 0.004, 0.004, 0.004, 0.003, 0
    ], edgeInset: 0.5, edgeSigma: 20)

    /// 其他窗口：阴影窄而浅，圆角处明显内收。
    static let inactive = WindowShadowProfile(vertical: [
        0.165, 0.163, 0.151, 0.141, 0.132, 0.121, 0.111, 0.101, 0.091, 0.078,
        0.069, 0.061, 0.049, 0.039, 0.034, 0.029, 0.024, 0.022, 0.014, 0.012,
        0.008, 0.008, 0.006, 0.004, 0.004, 0.001, 0
    ], top: [
        0.047, 0.030, 0.026, 0.022, 0.018, 0.013, 0.008, 0.008, 0.004, 0.004, 0.004, 0.001, 0
    ], edgeInset: 4, edgeSigma: 9.5)

    /// 阴影在窗口底边以下能到达的距离。
    var reach: Double { Double(vertical.count) }
    /// 阴影在窗口顶边以上能到达的距离。
    var topReach: Double { Double(top.count) }
    /// 阴影在窗口左右两端以外能到达的距离。
    var sideReach: Double { 3 * edgeSigma }

    /// 底边以下 `distance` 点处的不透明度；底边以上（窗口两侧）按贴边处的值。
    func vertical(at distance: Double) -> Double {
        guard distance > 0 else { return vertical.first ?? 0 }
        return Self.sample(vertical, at: distance)
    }

    /// 顶边以上 `distance` 点处的不透明度。
    func top(at distance: Double) -> Double { Self.sample(top, at: max(0, distance)) }

    private static func sample(_ table: [Double], at distance: Double) -> Double {
        let index = Int(distance)
        guard index + 1 < table.count else { return 0 }
        let t = distance - Double(index)
        return table[index] * (1 - t) + table[index + 1] * t
    }

    /// 横向系数：窗口中段为 1，左右边缘附近按高斯边缘渐隐。
    func horizontal(at x: Double, minX: Double, maxX: Double) -> Double {
        Self.phi((x - minX - edgeInset) / edgeSigma) * Self.phi((maxX - edgeInset - x) / edgeSigma)
    }

    static func phi(_ value: Double) -> Double { 0.5 * erfc(-value / 2.squareRoot()) }
}

struct WindowShadowCaster: Equatable, Sendable {
    /// 屏幕坐标（左下为原点，y 向上）。
    var frame: CGRect
    var active: Bool

    var profile: WindowShadowProfile { active ? .active : .inactive }
}

enum WindowShadowRenderer {
    /// 与区域相关的窗口：阴影能到达区域内。保持输入的前后顺序（最前的窗口在前）。
    static func relevant(_ casters: [WindowShadowCaster], in region: CGRect) -> [WindowShadowCaster] {
        casters.filter { caster in
            let profile = caster.profile
            return caster.frame.minY < region.maxY + profile.reach
                && caster.frame.maxY + profile.topReach > region.minY
                && caster.frame.maxX + profile.sideReach > region.minX
                && caster.frame.minX - profile.sideReach < region.maxX
        }
    }

    /// 区域内每个像素的阴影不透明度（0...255），按行自上而下。
    /// `casters` 须按前后顺序排列：前面窗口的本体会挡住后面窗口的阴影，自己的本体上也没有阴影；
    /// 多个阴影按真实合成叠加：1 - Π(1 - a)。`exclusions` 内不画（例如画面里已经带着阴影的补底）。
    static func alphaMap(region: CGRect, scale: Double, casters: [WindowShadowCaster],
                         exclusions: [CGRect] = []) -> (width: Int, height: Int, alpha: [UInt8]) {
        let width = max(0, Int((region.width * scale).rounded()))
        let height = max(0, Int((region.height * scale).rounded()))
        guard width > 0, height > 0 else { return (width, height, []) }
        let xs = (0..<width).map { Double(region.minX) + (Double($0) + 0.5) / scale }
        let ys = (0..<height).map { Double(region.maxY) - (Double($0) + 0.5) / scale }
        var remaining = [Double](repeating: 1, count: width * height)
        var occluders = exclusions
        for caster in relevant(casters, in: region) {
            let profile = caster.profile
            let frame = caster.frame
            let columns = xs.map { profile.horizontal(at: $0, minX: Double(frame.minX), maxX: Double(frame.maxX)) }
            occluders.append(frame)
            for row in 0..<height {
                let y = ys[row]
                let vertical = y > Double(frame.maxY) ? profile.top(at: y - Double(frame.maxY)) : profile.vertical(at: Double(frame.minY) - y)
                guard vertical > 0 else { continue }
                let rowOccluders = occluders.filter { Double($0.minY) <= y && y <= Double($0.maxY) }
                for column in 0..<width {
                    let a = vertical * columns[column]
                    guard a > 0.0005 else { continue }
                    let x = xs[column]
                    if rowOccluders.contains(where: { Double($0.minX) <= x && x <= Double($0.maxX) }) { continue }
                    remaining[row * width + column] *= 1 - a
                }
            }
        }
        let alpha = remaining.map { UInt8(max(0, min(255, ((1 - $0) * 255).rounded()))) }
        return (width, height, alpha)
    }
}
