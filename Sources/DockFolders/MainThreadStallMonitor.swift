import Foundation
import Darwin

/// 诊断：主线程一次连续忙超过 50 ms 时，从旁路线程抓几次主线程调用栈，结束后写进活动日志。
/// 卡到第三次采样（约 0.4 秒）时，其他线程的栈也一并记下：主线程常卡在窗口服务连接锁上（10-24 卡顿栈 25 次），
/// 只看主线程不知道是谁占着锁。
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
    private var others: [[UInt]] = []
    /// 空闲的派发工作线程停在这里，不记。
    private static let idleTrap = UInt(bitPattern: dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__workq_kernreturn")) & 0x0000_7FFF_FFFF_FFFF
    private static let threshold: TimeInterval = 0.05
    private static let sampleAt: [TimeInterval] = [0.05, 0.15, 0.4]
    /// 每分钟最多记几条（只在主线程读写）：出过一阵循环卡顿，一小时记了一千多条栈，日志涨到 60 MB。
    /// 超出的只计数，下一条记录时一并说明。
    private static let perMinute = 6
    private var minuteStart: TimeInterval = 0
    private var recordedThisMinute = 0
    private var suppressed = 0

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
        lock.withLock { busySince = ProcessInfo.processInfo.systemUptime; span += 1; samples.removeAll(keepingCapacity: true); others = [] }
        timer?.schedule(deadline: .now() + Self.sampleAt[0], repeating: .milliseconds(10))
    }

    private func ended() -> String? {
        timer?.schedule(deadline: .distantFuture)
        let (since, taken, otherStacks) = lock.withLock { () -> (TimeInterval?, [(at: TimeInterval, frames: [UInt])], [[UInt]]) in
            defer { busySince = nil; samples.removeAll(keepingCapacity: true); others = [] }
            return (busySince, samples, others)
        }
        guard let since else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - since
        guard elapsed >= Self.threshold else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if now - minuteStart >= 60 { minuteStart = now; recordedThisMinute = 0 }
        guard recordedThisMinute < Self.perMinute else { suppressed += 1; return nil }
        recordedThisMinute += 1
        let skipped = suppressed == 0 ? "" : "；此前另有 \(suppressed) 次卡顿超出每分钟 \(Self.perMinute) 条未记"
        suppressed = 0
        let stacks = taken.map { sample in
            String(format: "[%.0f ms] ", sample.at * 1_000) + sample.frames.map { String(format: "0x%lx", $0) }.joined(separator: " ")
        }
        let otherText = otherStacks.map { $0.map { String(format: "0x%lx", $0) }.joined(separator: " ") }
        return String(format: "主线程卡顿 %.0f ms（pid %d）", elapsed * 1_000, getpid()) + skipped
            + (stacks.isEmpty ? "" : "；栈：" + stacks.joined(separator: " | "))
            + (otherText.isEmpty ? "" : "；其他线程：" + otherText.joined(separator: " || "))
    }

    private func sample() {
        let state = lock.withLock { () -> (span: Int, at: TimeInterval, last: Bool)? in
            guard let busySince else { return nil }
            let at = ProcessInfo.processInfo.systemUptime - busySince
            guard samples.count < Self.sampleAt.count, at >= Self.sampleAt[samples.count] else { return nil }
            return (span, at, samples.count == Self.sampleAt.count - 1)
        }
        guard let state else { return }
        let frames = captureMainStack()
        let otherStacks = state.last ? captureOtherThreads() : []
        lock.withLock {
            if span == state.span, busySince != nil { samples.append((state.at, frames)); if state.last { others = otherStacks } }
        }
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

    /// 其他线程的栈。不知道各线程的栈范围，沿帧指针链读内存一律用 mach_vm_read_overwrite：地址无效时返回错误而不是崩溃。
    /// 暂停某个线程期间同样不分配内存、不取锁；每次只暂停一个线程。跳过主线程、本旁路线程和空闲的派发工作线程。
    private func captureOtherThreads() -> [[UInt]] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        let me = mach_thread_self()
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            mach_port_deallocate(mach_task_self_, me)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var result: [[UInt]] = []
        var buffer = [UInt](repeating: 0, count: 48)
        for index in 0..<Int(count) {
            let thread = list[index]
            guard thread != mainThread, thread != me else { continue }
            var frameCount = 0
            guard thread_suspend(thread) == KERN_SUCCESS else { continue }
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &state) { pointer in
                pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
                }
            }
            if status == KERN_SUCCESS {
                buffer.withUnsafeMutableBufferPointer { frames in
                    frames[0] = UInt(state.__pc) & mask
                    frames[1] = UInt(state.__lr) & mask
                    frameCount = 2
                    var fp = UInt(state.__fp)
                    var record: (UInt, UInt) = (0, 0)
                    while frameCount < frames.count, fp != 0, fp & 7 == 0 {
                        var read: mach_vm_size_t = 0
                        let copied = withUnsafeMutableBytes(of: &record) { bytes in
                            mach_vm_read_overwrite(mach_task_self_, mach_vm_address_t(fp), 16,
                                                   mach_vm_address_t(UInt(bitPattern: bytes.baseAddress)), &read)
                        }
                        guard copied == KERN_SUCCESS, read == 16 else { break }
                        let returnAddress = record.1 & mask
                        guard returnAddress != 0 else { break }
                        frames[frameCount] = returnAddress; frameCount += 1
                        guard record.0 > fp else { break }
                        fp = record.0
                    }
                }
            }
            thread_resume(thread)
            guard frameCount > 0, Self.idleTrap == 0 || !(buffer[0] >= Self.idleTrap && buffer[0] < Self.idleTrap + 32) else { continue }
            result.append(Array(buffer.prefix(frameCount)))
        }
        return result
    }
}
