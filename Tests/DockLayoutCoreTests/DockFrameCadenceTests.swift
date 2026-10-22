import Foundation
import Testing
@testable import DockLayoutCore

@Test func `帧间隔统计排除正常空闲且保留真实慢帧`() {
    var cadence = DockFrameCadence()
    cadence.record(at: 1, expectedInterval: 0.01, workDuration: 0.001)
    cadence.record(at: 1.01, expectedInterval: 0.01, workDuration: 0.002)
    cadence.record(at: 1.05, expectedInterval: 0.01, workDuration: 0.008)
    cadence.endActiveSegment()
    cadence.record(at: 15, expectedInterval: 0.01, workDuration: 0.001)
    #expect(cadence.sampleCount == 4)
    #expect(cadence.intervalCount == 2)
    #expect(cadence.delayedIntervalCount == 1)
    #expect(abs(cadence.maximumInterval - 0.04) < 0.000_001)
    #expect(cadence.maximumWork == 0.008)
}

@Test func `帧统计使用固定容量并淘汰旧卡顿`() {
    var cadence = DockFrameCadence(capacity: 3)
    cadence.record(at: 1, expectedInterval: 0.01, workDuration: 0.001)
    cadence.record(at: 1.08, expectedInterval: 0.01, workDuration: 0.030)
    for index in 1...3 { cadence.record(at: 1.08 + Double(index) * 0.01, expectedInterval: 0.01, workDuration: 0.001) }
    #expect(cadence.sampleCount == 3)
    #expect(cadence.intervalCount == 3)
    #expect(cadence.delayedIntervalCount == 0)
    #expect(cadence.workP95 == 0.001)
    #expect(abs(cadence.intervalP95 - 0.01) < 0.000_001)
}

@Test func `帧统计拒绝非有限值与错误时间范围`() {
    var cadence = DockFrameCadence()
    cadence.record(at: .nan, expectedInterval: 0.01, workDuration: 0.001)
    cadence.record(at: 1, expectedInterval: 0, workDuration: 0.001)
    cadence.record(at: 1, expectedInterval: 0.01, workDuration: -1)
    #expect(cadence.sampleCount == 0)
    cadence.record(at: 2, expectedInterval: 0.01, workDuration: 0.001)
    cadence.record(at: 1, expectedInterval: 0.01, workDuration: 0.001)
    #expect(cadence.intervalCount == 0)
}

@Test func `整帧忙碌时长单独统计且可清零`() {
    var cadence = DockFrameCadence(capacity: 3)
    for value in [0.002, 0.004, 0.020, 0.003] { cadence.recordBusy(value) }
    cadence.recordBusy(.nan)
    #expect(cadence.busyCount == 3)
    #expect(cadence.maximumBusy == 0.020)
    #expect(cadence.busyP95 == 0.020)
    cadence.record(at: 1, expectedInterval: 0.01, workDuration: 0.001)
    cadence.reset()
    #expect(cadence.busyCount == 0 && cadence.sampleCount == 0)
}
