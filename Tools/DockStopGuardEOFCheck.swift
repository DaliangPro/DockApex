import AppKit
import Darwin
import Foundation

/// 默认只读输出原生 Dock 身份。只有显式 --exercise-eof 才执行一次短暂停顿测试。
/// 不写偏好、不重启 Dock、不启动主工具；失败时只条件恢复本次同身份目标。
@main
@MainActor
struct DockStopGuardEOFCheck {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(EXIT_FAILURE) }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let target = currentDock(), !target.stopped else { throw Failure(message: "没有找到同用户且正常运行的系统 Dock，未发送信号。") }
        let encoded = try JSONEncoder().encode(target.identity).base64EncodedString()
        if args.isEmpty || args == ["--capture-only"] {
            let value: [String: Any] = ["identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(target.identity)),
                                      "encodedToken": encoded, "signalsSent": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return
        }
        guard args.count == 3, args[0] == "--exercise-eof" else {
            throw Failure(message: "用法：--capture-only；或 --exercise-eof 恢复助手路径 结果JSON路径。")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "io.daliang.dockfolders").allSatisfy(\.isTerminated) else {
            throw Failure(message: "主工具仍在运行，未执行真实暂停测试。")
        }
        let helper = URL(fileURLWithPath: args[1]).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Failure(message: "恢复助手不存在或不可执行。") }
        let process = Process(), input = Pipe(), output = Pipe()
        let writeFD = input.fileHandleForWriting.fileDescriptor
        let readFD = output.fileHandleForReading.fileDescriptor
        let readFlags = fcntl(readFD, F_GETFL)
        guard fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0,
              readFlags >= 0, fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) == 0 else {
            throw Failure(message: "无法建立有界测试管道，未执行暂停。")
        }
        process.executableURL = helper
        process.arguments = ["--guard-dock-stop", encoded]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        var attemptedPause = false
        var helperProvedRecovery = false
        defer {
            try? input.fileHandleForWriting.close()
            // 只在测试失败时保底；这种恢复不会被计为助手测试通过。
            if attemptedPause, !helperProvedRecovery, let current = DockStopGuardIdentity.captureDock(target.identity.processID),
               current.identity == target.identity, current.stopped { _ = kill(target.identity.processID, SIGCONT) }
        }
        var reader = LineReader(fd: readFD)
        guard try reader.read(timeout: 0.5).hasPrefix("READY ") else { throw Failure(message: "助手没有准备就绪，未执行暂停。") }
        let started = ProcessInfo.processInfo.systemUptime
        var command: UInt8 = 83
        guard write(writeFD, &command, 1) == 1 else { throw Failure(message: "没有成功请求暂停。") }
        attemptedPause = true
        guard try reader.read(timeout: 0.35).hasPrefix("STOPPED "),
              let paused = DockStopGuardIdentity.captureDock(target.identity.processID), paused.identity == target.identity, paused.stopped else {
            throw Failure(message: "未独立确认同一个 Dock 已暂停，测试不通过。")
        }
        let eofAt = ProcessInfo.processInfo.systemUptime
        try input.fileHandleForWriting.close()
        let deadline = started + 2
        var restoredAt: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let observed = DockStopGuardIdentity.captureDock(target.identity.processID), observed.identity == target.identity else {
                throw Failure(message: "Dock 进程身份改变，不能把重启或替换当作恢复成功。")
            }
            if !observed.stopped { restoredAt = ProcessInfo.processInfo.systemUptime; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let restoredAt else { throw Failure(message: "助手未在两秒内恢复同一个 Dock；测试不通过并执行条件恢复。") }
        helperProvedRecovery = true
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
        guard !process.isRunning, process.terminationStatus == 0 else { throw Failure(message: "Dock 已恢复，但一次性助手没有及时正常退出。") }
        let report: [String: Any] = ["passed": true, "dockIdentity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(target.identity)),
                                    "helperPID": process.processIdentifier, "helperExitStatus": process.terminationStatus,
                                    "pauseIndependentlyConfirmed": true, "samePIDAndBirthAfterResume": true,
                                    "millisecondsFromRequestToResume": (restoredAt - started) * 1_000,
                                    "millisecondsFromEOFToResume": (restoredAt - eofAt) * 1_000,
                                    "fallbackSIGCONTUsed": false, "preferenceWrites": false, "dockRestarted": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func currentDock() -> (identity: DockStopGuardIdentity, stopped: Bool)? {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let count = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.size) {
            if let snapshot = DockStopGuardIdentity.captureDock(pid) { return snapshot }
        }
        return nil
    }

    private struct LineReader {
        let fd: Int32
        var buffer = Data()
        mutating func read(timeout: TimeInterval) throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let end = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<end], as: UTF8.self)
                    buffer.removeSubrange(...end)
                    return line
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let available = poll(&descriptor, 1, 10)
                if available == 0 || (available < 0 && errno == EINTR) { continue }
                guard available > 0 else { break }
                var bytes = [UInt8](repeating: 0, count: 256)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)); if buffer.count > 512 { break } }
                else if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                else { break }
            }
            throw Failure(message: "助手握手没有在期限内完成，测试不通过。")
        }
    }
}
