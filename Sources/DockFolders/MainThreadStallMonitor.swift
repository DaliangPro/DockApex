import Foundation
import Darwin

/// 诊断：主线程一次连续忙超过 50 ms 时，从旁路线程抓几次主线程调用栈，结束后写进活动日志。
/// 只记原始返回地址；事后在应用仍运行时用 `atos -p <pid> 地址…` 还原函数名。
/// 主线程空闲（run loop 在等待）时不唤醒旁路线程。
final class MainThreadStallMonitor: @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.daliang.dockfolders.stall-monitor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var observer: CFRunLoopObserver?
    private var mainThread: thread_act_t = 0
    private var stack: ClosedRange<UInt> = 0...0
    private var busySince: TimeInterval?
    private var span = 0
    private var samples: [(at: TimeInterval, frames: [UInt])] = []
    private static let threshold: TimeInterval = 0.05
    private static let sampleAt: [TimeInterval] = [0.05, 0.15, 0.4]

    @MainActor
    func start(report: @escaping @MainActor (String) -> Void) {
        guard observer == nil else { return }
        mainThread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stack = (top - UInt(pthread_get_stacksize_np(pthread_self())))...top
        timer = makeTimer()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            guard let self else { return }
            if activity == .afterWaiting { self.began() }
            else if let message = self.ended() { MainActor.assumeIsolated { report(message) } }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// 不能在 start 里直接写回调：那样回调随 start 归主线程，在旁路队列触发时会因隔离断言崩溃。
    private func makeTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        return timer
    }

    private func began() {
        lock.withLock { busySince = ProcessInfo.processInfo.systemUptime; span += 1; samples.removeAll(keepingCapacity: true) }
        timer?.schedule(deadline: .now() + Self.sampleAt[0], repeating: .milliseconds(10))
    }

    private func ended() -> String? {
        timer?.schedule(deadline: .distantFuture)
        let (since, taken) = lock.withLock { () -> (TimeInterval?, [(at: TimeInterval, frames: [UInt])]) in
            defer { busySince = nil; samples.removeAll(keepingCapacity: true) }
            return (busySince, samples)
        }
        guard let since else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - since
        guard elapsed >= Self.threshold else { return nil }
        let stacks = taken.map { sample in
            String(format: "[%.0f ms] ", sample.at * 1_000) + sample.frames.map { String(format: "0x%lx", $0) }.joined(separator: " ")
        }
        return String(format: "主线程卡顿 %.0f ms（pid %d）", elapsed * 1_000, getpid())
            + (stacks.isEmpty ? "" : "；栈：" + stacks.joined(separator: " | "))
    }

    private func sample() {
        let state = lock.withLock { () -> (span: Int, at: TimeInterval)? in
            guard let busySince else { return nil }
            let at = ProcessInfo.processInfo.systemUptime - busySince
            guard samples.count < Self.sampleAt.count, at >= Self.sampleAt[samples.count] else { return nil }
            return (span, at)
        }
        guard let state else { return }
        let frames = captureMainStack()
        lock.withLock { if span == state.span, busySince != nil { samples.append((state.at, frames)) } }
    }

    /// 暂停主线程期间不分配内存、不取锁（主线程可能正持有 malloc 锁），只沿帧指针链读栈。
    private func captureMainStack() -> [UInt] {
        var buffer = [UInt](repeating: 0, count: 48)
        var count = 0
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF // 去掉系统库返回地址上的指针签名位
        let stack = self.stack
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            buffer.withUnsafeMutableBufferPointer { frames in
                frames[0] = UInt(state.__pc) & mask
                frames[1] = UInt(state.__lr) & mask
                count = 2
                var fp = UInt(state.__fp)
                while count < frames.count, fp & 7 == 0, stack.contains(fp), stack.contains(fp + 15),
                      let record = UnsafePointer<UInt>(bitPattern: fp) {
                    let next = record[0], returnAddress = record[1] & mask
                    guard returnAddress != 0 else { break }
                    frames[count] = returnAddress; count += 1
                    guard next > fp else { break }
                    fp = next
                }
            }
        }
        thread_resume(mainThread)
        return Array(buffer.prefix(count))
    }
}
