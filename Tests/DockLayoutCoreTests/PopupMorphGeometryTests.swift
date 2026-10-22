import CoreGraphics
import Testing
@testable import DockLayoutCore

@Suite("文件夹来源图标展开几何")
struct PopupMorphGeometryTests {
    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000_001 }
    private func assertPoint(_ a: CGPoint, _ b: CGPoint) {
        #expect(close(a.x, b.x)); #expect(close(a.y, b.y))
    }
    private func assertRect(_ a: CGRect, _ b: CGRect) {
        assertPoint(a.origin, b.origin)
        #expect(close(a.width, b.width)); #expect(close(a.height, b.height))
    }

    @Test("底边、左边、右边及负坐标屏的四角中心精确映射")
    func endpoints() throws {
        let cases: [(CGRect, CGRect)] = [
            (CGRect(x: 1800, y: 8, width: 41, height: 51), CGRect(x: 1650, y: 71, width: 482, height: 274)),
            (CGRect(x: 1012, y: -1323, width: 39, height: 51), CGRect(x: 1024, y: -1260, width: 302, height: 176)),
            (CGRect(x: -1916, y: 450, width: 51, height: 39), CGRect(x: -1853, y: 330, width: 482, height: 274)),
            (CGRect(x: 3008 - 55, y: 600, width: 51, height: 39), CGRect(x: 2459, y: 520, width: 482, height: 274))
        ]
        for (source, target) in cases {
            let geometry = try #require(PopupMorphGeometry(sourceFrame: source, targetFrame: target, backingScale: 2))
            let fractions: [CGFloat] = [0, 0.5, 1]
            for x in fractions { for y in fractions {
                let original = CGPoint(x: target.minX + target.width * x, y: target.minY + target.height * y)
                assertPoint(geometry.mapTargetPoint(original, using: geometry.transform(at: 0)),
                            CGPoint(x: source.minX + source.width * x, y: source.minY + source.height * y))
                assertPoint(geometry.mapTargetPoint(original, using: geometry.transform(at: 1)), original)
                let collapsed = geometry.mapTargetPoint(original, using: geometry.transform(at: 0))
                assertPoint(geometry.mapTargetPoint(collapsed, using: geometry.transform(at: 0).inverted()), original)
            } }
            assertRect(geometry.mappedFrame(using: geometry.transform(at: 0)), source)
            assertRect(geometry.mappedFrame(using: geometry.transform(at: 1)), target)
        }
    }

    @Test("透明画布覆盖完整往返路径且高 DPI 边界对齐像素")
    func canvas() throws {
        for scale: CGFloat in [1, 2, 3] {
            let geometry = try #require(PopupMorphGeometry(sourceFrame: CGRect(x: -800.3, y: -1320.4, width: 40.2, height: 50.6),
                targetFrame: CGRect(x: -940.7, y: -1257.8, width: 302.1, height: 176.2), backingScale: scale))
            for value in [geometry.canvasFrame.minX, geometry.canvasFrame.minY, geometry.canvasFrame.maxX, geometry.canvasFrame.maxY] {
                #expect(close(value * scale, (value * scale).rounded()))
            }
            for step in 0...20 {
                let progress = CGFloat(step) / 20
                let mapped = geometry.mappedFrame(using: geometry.transform(at: progress))
                #expect(geometry.canvasFrame.contains(mapped))
                assertRect(mapped.offsetBy(dx: -geometry.canvasFrame.minX, dy: -geometry.canvasFrame.minY),
                    CGRect(x: geometry.sourceInCanvas.minX * (1 - progress) + geometry.targetInCanvas.minX * progress,
                           y: geometry.sourceInCanvas.minY * (1 - progress) + geometry.targetInCanvas.minY * progress,
                           width: geometry.sourceFrame.width * (1 - progress) + geometry.targetFrame.width * progress,
                           height: geometry.sourceFrame.height * (1 - progress) + geometry.targetFrame.height * progress))
            }
        }
    }

    @Test("收回沿展开路径逆向对称，进度可从真实变换恢复")
    func reversal() throws {
        let geometry = try #require(PopupMorphGeometry(sourceFrame: CGRect(x: 1968, y: -1320, width: 41, height: 51),
            targetFrame: CGRect(x: 1820, y: -1257, width: 482, height: 274), backingScale: 2))
        let expanded = (0...20).map { geometry.mappedFrame(using: geometry.transform(at: CGFloat($0) / 20)) }
        let collapsed = (0...20).map { geometry.mappedFrame(using: geometry.transform(at: 1 - CGFloat($0) / 20)) }
        for step in 0...20 {
            assertRect(expanded[step], collapsed[20 - step])
            #expect(close(geometry.progress(of: geometry.transform(at: CGFloat(step) / 20)), CGFloat(step) / 20))
        }
    }

    @Test("冷开忽略旧 presentation 终态，反向保留当前几何")
    func coldOpenAndReversal() throws {
        let geometry = try #require(PopupMorphGeometry(sourceFrame: CGRect(x: 2100.45, y: -1324, width: 39, height: 51),
            targetFrame: CGRect(x: 1968.95, y: -1260, width: 302, height: 176), backingScale: 2))
        assertRect(geometry.mappedFrame(using: geometry.startingTransform(coldOpen: true, current: .identity)), geometry.sourceFrame)
        let midway = geometry.transform(at: 0.42)
        #expect(geometry.startingTransform(coldOpen: false, current: midway) == midway)
        assertRect(geometry.mappedFrame(using: geometry.startingTransform(coldOpen: true, current: midway)), geometry.sourceFrame)
    }

    @Test("无效坐标与零尺寸被拒绝，避免除零或无限画布")
    func invalidFrames() {
        let valid = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(PopupMorphGeometry(sourceFrame: .zero, targetFrame: valid) == nil)
        #expect(PopupMorphGeometry(sourceFrame: valid, targetFrame: .null) == nil)
        #expect(PopupMorphGeometry(sourceFrame: valid, targetFrame: valid, backingScale: 0) == nil)
        #expect(PopupMorphGeometry(sourceFrame: CGRect(x: CGFloat.infinity, y: 0, width: 40, height: 40), targetFrame: valid) == nil)
    }
}
