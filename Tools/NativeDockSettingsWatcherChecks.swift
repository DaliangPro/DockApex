// 离线检查：用临时目录里的偏好文件代替系统 Dock 偏好，用 defaults 经 cfprefsd 改值（整份替换文件，与系统写偏好的方式相同），
// 监视应先回调一次当前值，改了跟随的键后回调新值，改无关的键不回调。不读写系统 Dock 偏好、不动指针。
import Foundation

@main
struct NativeDockSettingsWatcherChecks {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var values: [NativeDockSettingsWatcher.Values] = []
        func add(_ value: NativeDockSettingsWatcher.Values) { lock.withLock { values.append(value) } }
        var count: Int { lock.withLock { values.count } }
        var lastValue: NativeDockSettingsWatcher.Values? { lock.withLock { values.last } }
    }

    static func defaults(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        try? process.run(); process.waitUntilExit()
    }

    static func wait(_ recorder: Recorder, count: Int, seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while recorder.count < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return recorder.count >= count
    }

    static func main() {
        let domain = NSTemporaryDirectory() + "dockapex-settings-check-\(getpid())"
        defaults(["write", domain, "magnification", "-bool", "false"])
        defaults(["write", domain, "largesize", "-int", "64"])
        let recorder = Recorder()
        let watcher = NativeDockSettingsWatcher(path: domain + ".plist") { recorder.add($0) }
        watcher.start()
        var checks = 0
        precondition(wait(recorder, count: 1), "启动后应先回调一次当前值")
        precondition(recorder.lastValue?.magnification == false && recorder.lastValue?.largeSize == 64, "初始值应与偏好一致")
        checks += 2
        defaults(["write", domain, "magnification", "-bool", "true"])
        defaults(["write", domain, "largesize", "-int", "96"])
        precondition(wait(recorder, count: 2), "改了放大后应回调")
        Thread.sleep(forTimeInterval: 0.6)
        precondition(recorder.lastValue?.magnification == true && recorder.lastValue?.largeSize == 96, "回调的应是新值")
        checks += 2
        let before = recorder.count
        defaults(["write", domain, "autohide-delay", "-float", "1"])
        Thread.sleep(forTimeInterval: 1.5)
        precondition(recorder.count == before, "改无关的键不应回调")
        checks += 1
        defaults(["write", domain, "show-process-indicators", "-bool", "false"])
        precondition(wait(recorder, count: before + 1), "文件被整份替换后仍应继续监视")
        precondition(recorder.lastValue?.showRunningIndicators == false, "运行指示应跟随")
        checks += 2
        print("checksPassed \(checks)")
    }
}
