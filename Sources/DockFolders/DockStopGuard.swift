import Darwin
import Foundation

struct DockStopGuardIdentity: Codable, Equatable, Sendable {
    let version: Int
    let processID: Int32
    let userID: UInt32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static let dockExecutable = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

    var isAllowedForCurrentUser: Bool {
        version == 1 && processID > 1 && userID == getuid() && executablePath == Self.dockExecutable
            && startSeconds > 0 && startMicroseconds < 1_000_000
    }

    static func captureDock(_ pid: Int32) -> (identity: Self, stopped: Bool)? {
        var info = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length,
              info.pbi_uid == getuid() else { return nil }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard count > 0, path == dockExecutable else { return nil }
        let identity = Self(version: 1, processID: pid, userID: info.pbi_uid, executablePath: path,
                            startSeconds: UInt64(info.pbi_start_tvsec), startMicroseconds: UInt64(info.pbi_start_tvusec))
        return (identity, info.pbi_status == UInt32(SSTOP))
    }
}

enum DockStopGuardError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum DockStopGuardProtocol {
    static let standbyLifetime: TimeInterval = 0.8
    static let pauseLifetime: TimeInterval = 1.6
    static let pollingMilliseconds: Int32 = 25

    /// 纯判定供离线核验；只有本助手确实暂停过的同身份 Dock 才能收到恢复信号。
    static func shouldResume(expected: DockStopGuardIdentity, actual: DockStopGuardIdentity?,
                             isStopped: Bool, ownsPause: Bool) -> Bool {
        expected.isAllowedForCurrentUser && actual == expected && isStopped && ownsPause
    }

    static func selfTest() throws -> String {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw DockStopGuardError.message("暂停恢复检查失败：\(message)") }
            count += 1
        }
        let token = DockStopGuardIdentity(version: 1, processID: 3456, userID: getuid(), executablePath: DockStopGuardIdentity.dockExecutable,
                                         startSeconds: 100, startMicroseconds: 123)
        try check(shouldResume(expected: token, actual: token, isStopped: true, ownsPause: true), "父退出或期限到达时恢复自己暂停的 Dock")
        try check(!shouldResume(expected: token, actual: nil, isStopped: true, ownsPause: true), "目标已退出不发送信号")
        try check(!shouldResume(expected: token, actual: token, isStopped: false, ownsPause: true), "正常运行目标不发送信号")
        try check(!shouldResume(expected: token, actual: token, isStopped: true, ownsPause: false), "没有暂停所有权不恢复其他暂停")
        let reused = DockStopGuardIdentity(version: 1, processID: token.processID, userID: token.userID, executablePath: token.executablePath,
                                          startSeconds: 101, startMicroseconds: 123)
        try check(!shouldResume(expected: token, actual: reused, isStopped: true, ownsPause: true), "PID 复用不发送信号")
        let otherUser = DockStopGuardIdentity(version: 1, processID: token.processID, userID: token.userID &+ 1, executablePath: token.executablePath,
                                             startSeconds: 100, startMicroseconds: 123)
        try check(!otherUser.isAllowedForCurrentUser && !shouldResume(expected: otherUser, actual: otherUser, isStopped: true, ownsPause: true), "拒绝其他用户")
        let otherPath = DockStopGuardIdentity(version: 1, processID: token.processID, userID: token.userID, executablePath: "/usr/bin/sleep",
                                             startSeconds: 100, startMicroseconds: 123)
        try check(!otherPath.isAllowedForCurrentUser && !shouldResume(expected: otherPath, actual: otherPath, isStopped: true, ownsPause: true), "拒绝非系统 Dock 可执行路径")
        let badVersion = DockStopGuardIdentity(version: 2, processID: token.processID, userID: token.userID, executablePath: token.executablePath,
                                              startSeconds: 100, startMicroseconds: 123)
        try check(!badVersion.isAllowedForCurrentUser, "拒绝未知协议")
        let encoded = try JSONEncoder().encode(token)
        try check(try JSONDecoder().decode(DockStopGuardIdentity.self, from: encoded) == token, "身份编码保留全部字段")
        try check(pauseLifetime + Double(pollingMilliseconds) / 1_000 < 2, "暂停恢复预算小于两秒")
        try check(DockStopGuardIdentity.captureDock(getpid()) == nil, "本检查进程不能冒充系统 Dock")
        return "一次性 Dock 暂停恢复离线检查 \(count) 项通过；没有暂停或恢复任何系统进程。"
    }
}

/// 主工具在停止 Dock 前启动的短寿命助手；不写偏好或磁盘，不依赖主工具继续运行。
enum DockStopGuardHelper {
    static func run(encodedIdentity: String) throws {
        guard encodedIdentity.count < 4_096, let data = Data(base64Encoded: encodedIdentity),
              let expected = try? JSONDecoder().decode(DockStopGuardIdentity.self, from: data), expected.isAllowedForCurrentUser,
              let initial = DockStopGuardIdentity.captureDock(expected.processID), initial.identity == expected, !initial.stopped else {
            throw DockStopGuardError.message("Dock 暂停助手身份校验失败，未发送信号。")
        }
        // 父进程随时可能关闭输出管道；写入失败也必须走 defer 恢复，不能被 SIGPIPE 提前结束。
        signal(SIGPIPE, SIG_IGN)
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DockStopGuardError.message("无法建立有界暂停控制通道。")
        }
        var ownsPause = false
        defer {
            if let current = DockStopGuardIdentity.captureDock(expected.processID),
               DockStopGuardProtocol.shouldResume(expected: expected, actual: current.identity, isStopped: current.stopped, ownsPause: ownsPause) {
                _ = kill(expected.processID, SIGCONT)
            }
        }
        let standbyDeadline = ProcessInfo.processInfo.systemUptime + DockStopGuardProtocol.standbyLifetime
        try send("READY \(standbyDeadline)\n")
        while ProcessInfo.processInfo.systemUptime < standbyDeadline {
            switch control(deadline: standbyDeadline) {
            case .none: continue
            case .closed: return
            case .begin:
                guard ProcessInfo.processInfo.systemUptime < standbyDeadline,
                      let current = DockStopGuardIdentity.captureDock(expected.processID), current.identity == expected, !current.stopped else {
                    throw DockStopGuardError.message("Dock 在暂停前已有变化，未发送暂停信号。")
                }
                // 只有助手发送 SIGSTOP。父线程即便很晚才恢复，也不能在助手退出后再暂停 Dock。
                let pauseDeadline = ProcessInfo.processInfo.systemUptime + DockStopGuardProtocol.pauseLifetime
                guard kill(expected.processID, SIGSTOP) == 0 else { throw DockStopGuardError.message("一次性助手无法暂停已核验的 Dock。") }
                ownsPause = true
                let confirmationDeadline = min(pauseDeadline, ProcessInfo.processInfo.systemUptime + 0.12)
                var confirmed = false
                while ProcessInfo.processInfo.systemUptime < confirmationDeadline {
                    guard let observed = DockStopGuardIdentity.captureDock(expected.processID), observed.identity == expected else { return }
                    if observed.stopped { confirmed = true; break }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard confirmed else { throw DockStopGuardError.message("Dock 未及时进入暂停状态，已取消提交。") }
                try send("STOPPED \(pauseDeadline)\n")
                while ProcessInfo.processInfo.systemUptime < pauseDeadline {
                    guard let observed = DockStopGuardIdentity.captureDock(expected.processID), observed.identity == expected, observed.stopped else { return }
                    if control(deadline: pauseDeadline) != .none { return }
                }
                return
            }
        }
    }

    private enum Control { case none, begin, closed }
    private static func control(deadline: TimeInterval) -> Control {
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard remaining > 0 else { return .closed }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let timeout = max(1, min(DockStopGuardProtocol.pollingMilliseconds, Int32(ceil(remaining * 1_000))))
        let result = poll(&descriptor, 1, timeout)
        if result == 0 || (result < 0 && errno == EINTR) { return .none }
        guard result > 0 else { return .closed }
        var command: UInt8 = 0
        let count = read(STDIN_FILENO, &command, 1)
        if count == 1 { return command == 83 ? .begin : .closed }
        if count < 0 && [EAGAIN, EINTR].contains(errno) { return .none }
        return .closed
    }
    private static func send(_ value: String) throws { try FileHandle.standardOutput.write(contentsOf: Data(value.utf8)) }
}

/// 主工具侧租约。arm 只启动助手，beginPause 才由助手暂停；cancel 不会杀掉恢复助手。
@MainActor
final class DockStopGuard {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private var deadline: TimeInterval
    private var buffer = Data()
    private var cancelled = false
    private var paused = false

    var remainingSeconds: Double { cancelled ? 0 : max(0, deadline - ProcessInfo.processInfo.systemUptime) }
    var hasTimeRemaining: Bool { remainingSeconds > 0.05 && process.isRunning }

    private init(process: Process, input: Pipe, output: Pipe, deadline: TimeInterval) {
        self.process = process; self.input = input; self.output = output; self.deadline = deadline
    }

    static func arm(processID: pid_t) throws -> DockStopGuard {
        guard let captured = DockStopGuardIdentity.captureDock(processID), !captured.stopped,
              let helper = Bundle.main.url(forResource: "DockRestoreAgent", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw DockStopGuardError.message("无法启动独立 Dock 暂停恢复助手，本次没有暂停 Dock。")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        let readFlags = fcntl(outputFD, F_GETFL)
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(inputFD, F_SETFD, FD_CLOEXEC) == 0, readFlags >= 0,
              fcntl(outputFD, F_SETFL, readFlags | O_NONBLOCK) == 0 else {
            throw DockStopGuardError.message("无法建立独立暂停恢复通道，本次没有暂停 Dock。")
        }
        process.executableURL = helper
        process.arguments = ["--guard-dock-stop", try JSONEncoder().encode(captured.identity).base64EncodedString()]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        let guardProcess = DockStopGuard(process: process, input: input, output: output,
                                         deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        do {
            guardProcess.deadline = try guardProcess.readDeadline(expected: "READY", timeout: 0.5,
                                                                maximumLifetime: DockStopGuardProtocol.standbyLifetime)
            guard guardProcess.hasTimeRemaining else { throw DockStopGuardError.message("暂停恢复助手准备超时，本次没有暂停 Dock。") }
            return guardProcess
        } catch { guardProcess.cancel(); throw error }
    }

    func beginPause() throws {
        guard !paused, hasTimeRemaining else { throw DockStopGuardError.message("暂停恢复租约已失效，本次没有再次暂停 Dock。") }
        var command: UInt8 = 83
        guard write(input.fileHandleForWriting.fileDescriptor, &command, 1) == 1 else {
            cancel()
            throw DockStopGuardError.message("无法请求有界 Dock 暂停。")
        }
        do {
            deadline = try readDeadline(expected: "STOPPED", timeout: 0.35, maximumLifetime: DockStopGuardProtocol.pauseLifetime)
            paused = true
            guard hasTimeRemaining else { throw DockStopGuardError.message("Dock 暂停恢复租约已经到期。") }
        } catch { cancel(); throw error }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        // EOF 让助手先条件恢复自己暂停的 Dock，再自然结束；不能直接 terminate 助手。
        try? input.fileHandleForWriting.close()
    }

    private func readDeadline(expected: String, timeout: TimeInterval, maximumLifetime: TimeInterval) throws -> TimeInterval {
        let readUntil = ProcessInfo.processInfo.systemUptime + timeout
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < readUntil {
            if let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                let parts = line.split(separator: " ")
                let now = ProcessInfo.processInfo.systemUptime
                guard parts.count == 2, parts[0] == expected, let deadline = Double(parts[1]), deadline.isFinite,
                      deadline > now, deadline <= now + maximumLifetime + 0.05 else {
                    throw DockStopGuardError.message("暂停恢复助手应答不正确，已取消提交。")
                }
                return deadline
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let status = poll(&descriptor, 1, 10)
            if status == 0 || (status < 0 && errno == EINTR) { continue }
            guard status > 0 else { break }
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)); if buffer.count > 512 { break } }
            else if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            else { break }
        }
        throw DockStopGuardError.message("独立暂停恢复助手未及时就绪，已取消本次 Dock 写入。")
    }
}
