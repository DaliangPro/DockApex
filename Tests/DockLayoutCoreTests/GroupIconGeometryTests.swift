import CoreGraphics
import Testing
@testable import DockLayoutCore

private let canvas = CGRect(x: 0, y: 0, width: 128, height: 128)

@Test func `两个成员落在底板上排左右两格`() {
    let plate = GroupIconGeometry.plate(in: canvas)
    let first = GroupIconGeometry.slot(0, memberCount: 2, in: canvas)
    let second = GroupIconGeometry.slot(1, memberCount: 2, in: canvas)
    #expect(abs(plate.width - 128 * 0.8046) < 0.1)
    #expect(first.minY == second.minY)
    #expect(first.maxX < second.minX)
    #expect(plate.contains(first) && plate.contains(second))
    // 左上格贴着底板左上角留白。
    #expect(abs(first.minX - (plate.minX + plate.width * 0.12)) < 0.001)
    #expect(abs(first.maxY - (plate.maxY - plate.width * 0.12)) < 0.001)
}

@Test func `五个成员起改为三列小格`() {
    let four = GroupIconGeometry.slot(3, memberCount: 4, in: canvas)
    let five = GroupIconGeometry.slot(3, memberCount: 5, in: canvas)
    #expect(four.width > five.width)
    // 4 个：第 4 个在第二行右格；5 个：第 4 个在第二行左格。
    #expect(four.minX > canvas.midX)
    #expect(five.minX < canvas.midX)
    let plate = GroupIconGeometry.plate(in: canvas)
    for index in 0..<9 { #expect(plate.contains(GroupIconGeometry.slot(index, memberCount: 9, in: canvas))) }
}
