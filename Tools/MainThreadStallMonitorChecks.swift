// 离线检查：主线程卡住约 1 秒时，卡顿记录里应带上其他线程的栈，用 atos 能在后台线程的栈里找到它正在执行的函数。
// 只在本进程里制造卡顿，不读写系统 Dock、不动指针。
import Foundation

nonisolated(unsafe) var sharedLock = NSLock()
@inline(never) func backgroundHoldsLock() {
    let lock = sharedLock
    lock.lock()
    Thread.sleep(forTimeInterval: 1.5)
    lock.unlock()
}

@main
struct MainThreadStallMonitorChecks {
    @MainActor static func main() {
        var messages: [String] = []
        // 命令行进程的主运行循环没有输入源时不会真正等待，监测靠“等待结束”开始计时；挂一个计时器让它照常等待。
        let keepAlive = Timer(timeInterval: 10, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .common)
        MainThreadStallMonitor.shared.start { messages.append($0) }
        let lock = sharedLock
        let worker = Thread { backgroundHoldsLock() }
        worker.start()
        // 让主线程进出一次 run loop 等待，监测才开始计时；然后卡在后台线程占着的锁上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            lock.lock(); lock.unlock()
        }
        let deadline = Date().addingTimeInterval(3)
        while messages.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let message = messages.first else { print("FAIL 没有卡顿记录"); exit(1) }
        guard let range = message.range(of: "；其他线程：") else { print("FAIL 没有其他线程：\(message.prefix(200))"); exit(1) }
        let threads = message[range.upperBound...].components(separatedBy: " || ")
        // 交给 atos 按本进程还原，看后台线程栈里有没有 backgroundHoldsLock。
        let addresses = threads.flatMap { $0.split(separator: " ").map(String.init) }
        let atos = Process()
        atos.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        atos.arguments = ["-p", String(getpid())] + addresses
        let pipe = Pipe(); atos.standardOutput = pipe
        try? atos.run(); atos.waitUntilExit()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let found = names.contains("backgroundHoldsLock")
        print("其他线程数", threads.count, "找到后台函数", found)
        exit(found ? 0 : 1)
    }
}
