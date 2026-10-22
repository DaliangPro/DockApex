import AppKit
import CoreGraphics
import Darwin
import Foundation

/// 三边系统区域原型。--snapshot 只读；写入必须显式给出 --edge/--display。
/// 最多持有约 0.7 秒，并有独立恢复子进程；仅由主任务统一运行。
/// 不申请 universal owner，不读取应用窗口，不写偏好，不触碰主产品。
private struct TrialRegion: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var reason: Int32
    var orientation: Int32

    init(_ rect: CGRect, reason: Int32, orientation: Int32) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
        self.reason = reason; self.orientation = orientation
    }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isFinite: Bool { [x, y, width, height].allSatisfy(\.isFinite) }
    var expanded: Self { Self(CGRect(x: x, y: y - 2, width: width, height: height + 2), reason: reason, orientation: orientation) }
    func matches(_ other: Self) -> Bool {
        reason == other.reason && orientation == other.orientation
            && zip([x, y, width, height], [other.x, other.y, other.width, other.height]).allSatisfy { abs($0 - $1) < 0.01 }
    }
}

private struct GuardPayload: Codable {
    var baseline: TrialRegion
    var trial: TrialRegion
    var parentPID: Int32
}

private struct TrialFailure: Error { var code: Int }

@MainActor
private final class DockRectAPI {
    typealias Connection = @convention(c) () -> Int32
    typealias Getter = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias Setter = @convention(c) (Int32, CGRect, Int32, Int32) -> Int32
    let connection: Int32
    private let getter: Getter
    private let setter: Setter
    private let handle: UnsafeMutableRawPointer

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connectionPointer = dlsym(handle, "SLSMainConnectionID"),
              let getPointer = dlsym(handle, "SLSGetDockRectWithOrientation"),
              let setPointer = dlsym(handle, "SLSSetDockRectWithOrientation") else { throw TrialFailure(code: 1) }
        self.handle = handle
        getter = unsafeBitCast(getPointer, to: Getter.self)
        setter = unsafeBitCast(setPointer, to: Setter.self)
        connection = unsafeBitCast(connectionPointer, to: Connection.self)()
        guard connection != 0 else { throw TrialFailure(code: 2) }
    }

    func read() throws -> TrialRegion {
        var rect = CGRect.zero, reason: Int32 = -1, orientation: Int32 = -1
        let status = getter(connection, &rect, &reason, &orientation)
        guard status == 0 else { throw TrialFailure(code: Int(status)) }
        let value = TrialRegion(rect, reason: reason, orientation: orientation)
        guard value.isFinite else { throw TrialFailure(code: 3) }
        return value
    }
    func set(_ value: TrialRegion) -> Int32 { setter(connection, value.rect, value.reason, value.orientation) }
}

@main
@MainActor
enum SystemDockEdgeTrial {
    static func main() {
        do {
            let api = try DockRectAPI()
            if CommandLine.arguments.contains("--snapshot") {
                emit(try snapshot(api)); return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--restore-guard") {
                guard CommandLine.arguments.indices.contains(index + 1),
                      let data = Data(base64Encoded: CommandLine.arguments[index + 1]) else { throw TrialFailure(code: 4) }
                let payload = try JSONDecoder().decode(GuardPayload.self, from: data)
                guard payload.parentPID == getppid(), payload.baseline.isFinite,
                      payload.baseline.width >= 0, payload.baseline.height >= 0,
                      validTrial(payload.trial) else { throw TrialFailure(code: 5) }
                runGuard(api, payload: payload); return
            }
            try runTrial(api)
        } catch {
            emit(["mode": "error", "errorCode": (error as? TrialFailure)?.code ?? -1,
                  "setterAttempted": false, "pid": getpid()])
            Darwin.exit(1)
        }
    }

    private static func runTrial(_ api: DockRectAPI) throws {
        let baseline = try api.read()
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let edge = argument("--edge"), ["bottom", "left", "right"].contains(edge),
              let displayText = argument("--display"), let display = UInt32(displayText),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
              }) else { throw TrialFailure(code: 6) }
        let depth = argument("--thickness").flatMap(Double.init) ?? 57
        guard depth.isFinite, depth >= 8, depth <= 96 else { throw TrialFailure(code: 7) }
        let bounds = CGDisplayBounds(display)
        let rectangle: CGRect
        let orientation: Int32
        switch edge {
        case "left":
            rectangle = CGRect(x: bounds.minX, y: bounds.minY, width: depth, height: bounds.height)
            orientation = 3
        case "right":
            rectangle = CGRect(x: bounds.maxX - depth, y: bounds.minY, width: depth, height: bounds.height)
            orientation = 4
        default:
            rectangle = CGRect(x: bounds.minX, y: bounds.maxY - depth, width: bounds.width, height: depth)
            orientation = 2
        }
        let trial = TrialRegion(rectangle, reason: 5, orientation: orientation)
        guard validTrial(trial) else { throw TrialFailure(code: 7) }
        _ = screen
        let before = try childSnapshot(timeoutMS: 800)
        guard let independentBefore = region(from: before), independentBefore.matches(baseline),
              try api.read().matches(baseline) else { throw TrialFailure(code: 8) }
        let payload = GuardPayload(baseline: baseline, trial: trial, parentPID: getpid())
        let guardProcess = Process()
        let guardInput = Pipe(), guardOutput = Pipe()
        guardProcess.executableURL = executableURL
        guardProcess.arguments = ["--restore-guard", try JSONEncoder().encode(payload).base64EncodedString()]
        guardProcess.standardInput = guardInput; guardProcess.standardOutput = guardOutput
        guardProcess.standardError = FileHandle.nullDevice
        try guardProcess.run()
        try? guardInput.fileHandleForReading.close(); try? guardOutput.fileHandleForWriting.close()
        guard try readLine(guardOutput.fileHandleForReading, timeoutMS: 800) == "READY" else {
            guardProcess.terminate(); throw TrialFailure(code: 9)
        }
        try guardInput.fileHandleForWriting.write(contentsOf: Data("ARM\n".utf8))
        let armedLine = try readLine(guardOutput.fileHandleForReading, timeoutMS: 150)
        guard armedLine.hasPrefix("ARMED "), let started = Double(armedLine.dropFirst(6)) else {
            try? guardInput.fileHandleForWriting.close(); throw TrialFailure(code: 10)
        }
        var output: [String: Any] = ["mode": "single-trial", "pid": getpid(), "before": before,
            "requested": dictionary(trial), "edge": edge, "displayID": display,
            "universalOwnerRequested": false, "holdingBudgetMS": 700]
        var restoreAttempted = false
        func restoreIfStillOwned() {
            guard !restoreAttempted else { return }
            restoreAttempted = true
            let current = try? api.read()
            output["ownBeforeRestore"] = current.map(dictionary) ?? NSNull()
            if current?.matches(trial) == true {
                output["restoreSetterSendStatus"] = api.set(baseline)
                output["restoreAttempted"] = true
            } else { output["restoreAttempted"] = false }
            output["holdingElapsedMS"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            output["ownAfterRestore"] = (try? api.read()).map(dictionary) ?? NSNull()
            try? guardInput.fileHandleForWriting.write(contentsOf: Data("RESTORED\n".utf8))
            try? guardInput.fileHandleForWriting.close()
        }
        defer { restoreIfStillOwned() }
        // ARMED 以后若父进程曾被长时间挂起，就不再开始写入。
        guard guardProcess.isRunning, ProcessInfo.processInfo.systemUptime - started < 0.1 else {
            output["setterAttempted"] = false
            output["errorCode"] = 17
            restoreIfStillOwned()
            emit(output)
            return
        }
        output["setterAttempted"] = true
        output["setterSendStatus"] = api.set(trial)
        output["ownDuring"] = (try? api.read()).map(dictionary) ?? NSNull()
        do { output["independentDuring"] = try childSnapshot(timeoutMS: 350) }
        catch { output["independentDuringErrorCode"] = (error as? TrialFailure)?.code ?? -1 }
        restoreIfStillOwned()
        do {
            let after = try childSnapshot(timeoutMS: 800)
            output["independentAfter"] = after
            output["independentRestoreVerified"] = region(from: after)?.matches(baseline) == true
            output["independentVisibleFrameRestored"] = screenValuesEqual(before, after)
        } catch { output["independentAfterErrorCode"] = (error as? TrialFailure)?.code ?? -1 }
        if let guardLine = try? readLine(guardOutput.fileHandleForReading, timeoutMS: 350),
           let data = guardLine.data(using: .utf8), let guardResult = try? JSONSerialization.jsonObject(with: data) {
            output["guardResult"] = guardResult
        }
        try? guardOutput.fileHandleForReading.close()
        if guardProcess.isRunning { guardProcess.terminate() }
        let during = output["independentDuring"] as? [String: Any]
        output["independentGetterChanged"] = during.flatMap(region).map { $0.matches(trial) } ?? false
        output["independentVisibleFrameChanged"] = during.map { !screenValuesEqual(before, $0) } ?? false
        output["holdingWithinOneSecond"] = (output["holdingElapsedMS"] as? Double ?? .infinity) <= 1000
        let duringScreen = (during?["screens"] as? [String: Any])?[String(display)] as? [String: Any]
        let visible = duringScreen?["visibleFrame"] as? [Double]
        let frame = duringScreen?["frame"] as? [Double]
        if let visible, visible.count == 4, let frame, frame.count == 4 {
            let measured: Double
            switch edge {
            case "left": measured = visible[0] - frame[0]
            case "right": measured = frame[0] + frame[2] - visible[0] - visible[2]
            default: measured = visible[1] - frame[1]
            }
            output["measuredInset"] = measured
            output["requestedInsetVerified"] = abs(measured - depth) < 0.1
        } else { output["requestedInsetVerified"] = false }
        // 原生 Dock 若原先已留出相同边距，矩形宽度变化不应被误判为试验失败。
        output["trialSucceeded"] = output["requestedInsetVerified"] as? Bool == true
            && output["independentGetterChanged"] as? Bool == true
            && output["independentRestoreVerified"] as? Bool == true
            && output["independentVisibleFrameRestored"] as? Bool == true
            && output["holdingWithinOneSecond"] as? Bool == true
        output["completedAtUptime"] = ProcessInfo.processInfo.systemUptime
        emit(output)
    }

    /// 恢复助手自行复核矩形只占一个现存显示器的完整边缘，不接受任意窗口区域。
    private static func validTrial(_ value: TrialRegion) -> Bool {
        guard value.isFinite, value.reason == 5, [2, 3, 4].contains(value.orientation),
              value.width > 0, value.height > 0 else { return false }
        return NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let bounds = CGDisplayBounds(id.uint32Value)
            func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
            switch value.orientation {
            case 2:
                return same(value.x, bounds.minX) && same(value.width, bounds.width)
                    && same(value.rect.maxY, bounds.maxY) && (8...96).contains(value.height)
                    && value.height < bounds.height * 0.15
            case 3, 4:
                let aligned = value.orientation == 3 ? same(value.x, bounds.minX) : same(value.rect.maxX, bounds.maxX)
                return aligned && same(value.y, bounds.minY) && same(value.height, bounds.height)
                    && (8...96).contains(value.width) && value.width < bounds.width * 0.15
            default: return false
            }
        }
    }

    private static func runGuard(_ api: DockRectAPI, payload: GuardPayload) {
        line("READY")
        guard (try? readLine(.standardInput, timeoutMS: 1200)) == "ARM" else { return }
        let started = ProcessInfo.processInfo.systemUptime
        line("ARMED \(started)")
        let command = try? readLine(.standardInput, timeoutMS: 700)
        var output: [String: Any] = ["guardElapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "parentReportedRestore": command == "RESTORED", "restoreAttempted": false]
        if let current = try? api.read() {
            output["before"] = dictionary(current)
            if current.matches(payload.trial) {
                output["restoreAttempted"] = true
                output["restoreSetterSendStatus"] = api.set(payload.baseline)
            }
        }
        output["after"] = (try? api.read()).map(dictionary) ?? NSNull()
        line(json(output))
    }

    private static var executableURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }

    private static func childSnapshot(timeoutMS: Int32) throws -> [String: Any] {
        let child = Process(), pipe = Pipe()
        child.executableURL = executableURL; child.arguments = ["--snapshot"]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run(); try? pipe.fileHandleForWriting.close()
        defer {
            try? pipe.fileHandleForReading.close()
            if child.isRunning { child.terminate() }
        }
        let response = try readLine(pipe.fileHandleForReading, timeoutMS: timeoutMS)
        guard let data = response.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["mode"] as? String == "snapshot" else { throw TrialFailure(code: 11) }
        return result
    }

    private static func snapshot(_ api: DockRectAPI) throws -> [String: Any] {
        let value = try api.read()
        var screens: [String: Any] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            screens[number.stringValue] = ["frame": rectValues(screen.frame), "visibleFrame": rectValues(screen.visibleFrame)]
        }
        return ["mode": "snapshot", "pid": getpid(), "connection": api.connection,
                "region": dictionary(value), "screens": screens, "uptime": ProcessInfo.processInfo.systemUptime]
    }

    private static func region(from snapshot: [String: Any]) -> TrialRegion? {
        guard let raw = snapshot["region"], let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(TrialRegion.self, from: data)
    }
    private static func screenValuesEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs["screens"] as? [String: Any] ?? [:]).isEqual(to: rhs["screens"] as? [String: Any] ?? [:])
    }
    private static func dictionary(_ region: TrialRegion) -> [String: Any] {
        ["x": region.x, "y": region.y, "width": region.width, "height": region.height,
         "reason": region.reason, "orientation": region.orientation]
    }
    private static func rectValues(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{\"errorCode\":12}" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func line(_ string: String) { try? FileHandle.standardOutput.write(contentsOf: Data((string + "\n").utf8)) }
    private static func emit(_ value: [String: Any]) { line(json(value)) }

    /// 绝不使用 readDataToEndOfFile 等待未退出的子进程。
    private static func readLine(_ handle: FileHandle, timeoutMS: Int32) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMS) / 1000
        var bytes: [UInt8] = []
        while bytes.count < 65536 {
            let remaining = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            guard remaining > 0 else { throw TrialFailure(code: 13) }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, remaining) > 0 else { throw TrialFailure(code: 14) }
            var byte: UInt8 = 0
            guard Darwin.read(handle.fileDescriptor, &byte, 1) == 1 else { throw TrialFailure(code: 15) }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw TrialFailure(code: 16)
    }
}
