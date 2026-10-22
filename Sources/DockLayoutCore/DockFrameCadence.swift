import Foundation

/// 有界主线程显示回调统计。空闲暂停后的首帧不计间隔，不采集图像，也不代表最终屏幕合成 FPS。
struct DockFrameCadence: Sendable {
    struct Sample: Sendable {
        let interval: TimeInterval?
        let expectedInterval: TimeInterval
        let workDuration: TimeInterval
    }

    private let capacity: Int
    private var samples: [Sample] = []
    private var nextIndex = 0
    private var lastTimestamp: TimeInterval?
    private var busy: [TimeInterval] = []
    private var nextBusyIndex = 0

    init(capacity: Int = 240) { self.capacity = max(1, capacity) }

    mutating func endActiveSegment() { lastTimestamp = nil }

    mutating func reset() {
        samples = []; nextIndex = 0; lastTimestamp = nil
        busy = []; nextBusyIndex = 0
    }

    /// 一帧从显示回调开始到主线程进入等待的总时长：含回调之后的 AppKit 布局、绘制和 Core Animation 提交。
    mutating func recordBusy(_ duration: TimeInterval) {
        guard duration.isFinite, duration >= 0 else { return }
        if busy.count < capacity { busy.append(duration) }
        else { busy[nextBusyIndex] = duration }
        nextBusyIndex = (nextBusyIndex + 1) % capacity
    }

    mutating func record(at timestamp: TimeInterval, expectedInterval: TimeInterval, workDuration: TimeInterval) {
        guard timestamp.isFinite, expectedInterval.isFinite, expectedInterval > 0,
              workDuration.isFinite, workDuration >= 0 else { return }
        let interval = lastTimestamp.flatMap { timestamp > $0 ? timestamp - $0 : nil }
        lastTimestamp = timestamp
        let sample = Sample(interval: interval, expectedInterval: expectedInterval, workDuration: workDuration)
        if samples.count < capacity { samples.append(sample) }
        else { samples[nextIndex] = sample }
        nextIndex = (nextIndex + 1) % capacity
    }

    var sampleCount: Int { samples.count }
    var intervalCount: Int { samples.compactMap(\.interval).count }
    var delayedIntervalCount: Int { samples.filter { sample in sample.interval.map { $0 > sample.expectedInterval * 1.5 } ?? false }.count }
    var intervalP95: TimeInterval { percentile95(samples.compactMap(\.interval)) }
    var maximumInterval: TimeInterval { samples.compactMap(\.interval).max() ?? 0 }
    var workP95: TimeInterval { percentile95(samples.map(\.workDuration)) }
    var maximumWork: TimeInterval { samples.map(\.workDuration).max() ?? 0 }
    var busyCount: Int { busy.count }
    var busyP95: TimeInterval { percentile95(busy) }
    var maximumBusy: TimeInterval { busy.max() ?? 0 }

    private func percentile95(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))]
    }
}
