import AppKit
import CoreGraphics
import Foundation

/// 只观察本进程的 NSScreen 对象；不登记区域、不查看窗口、不捕获屏幕。
@MainActor
private final class VisibleFrameObservation {
    private let cachedScreens: [NSScreen]
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var previousValues: Data?

    init(screens: [NSScreen]) { cachedScreens = screens }

    func sample() {
        let freshScreens = NSScreen.screens
        let comparable: [String: Any] = ["cachedScreens": cachedScreens.map { screenValue($0, includeIdentity: false) },
                                         "freshScreens": freshScreens.map { screenValue($0, includeIdentity: false) }]
        guard let encoded = try? JSONSerialization.data(withJSONObject: comparable, options: [.sortedKeys]),
              encoded != previousValues else { return }
        let initial = previousValues == nil
        previousValues = encoded
        var output: [String: Any] = ["cachedScreens": cachedScreens.map { screenValue($0, includeIdentity: true) },
                                     "freshScreens": freshScreens.map { screenValue($0, includeIdentity: true) }]
        output["event"] = initial ? "initial" : "changed"
        output["pid"] = ProcessInfo.processInfo.processIdentifier
        output["appKitLifecycle"] = true
        output["elapsedMS"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        output["uptime"] = ProcessInfo.processInfo.systemUptime
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
    }

    private func screenValue(_ screen: NSScreen, includeIdentity: Bool) -> [String: Any] {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        var result: [String: Any] = ["displayID": number?.uint32Value ?? 0,
                                      "frame": coordinates(screen.frame), "visibleFrame": coordinates(screen.visibleFrame)]
        if includeIdentity { result["objectIdentity"] = String(describing: ObjectIdentifier(screen)) }
        return result
    }

    private func coordinates(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height]
    }
}

@MainActor
private final class VisibleFrameProbeDelegate: NSObject, NSApplicationDelegate {
    private var observation: VisibleFrameObservation?
    private var sampleTimer: Timer?
    private var stopTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 在正常 AppKit 启动完成后保留同一组对象，并由 NSApplication.run 处理屏幕通知。
        let screens = NSScreen.screens
        let observation = VisibleFrameObservation(screens: screens)
        self.observation = observation
        observation.sample()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { observation.sample() }
        }
        timer.tolerance = 0.005
        sampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        let stop = Timer(timeInterval: 20, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
        stopTimer = stop
        RunLoop.main.add(stop, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sampleTimer?.invalidate(); stopTimer?.invalidate()
        observation = nil
    }
}

@main
@MainActor
enum VisibleFrameLiveProbe {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = VisibleFrameProbeDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
