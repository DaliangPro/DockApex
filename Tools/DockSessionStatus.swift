import AppKit
import CoreGraphics
import Darwin
import Foundation

// 只读诊断：不激活、重开或启动应用，不移动指针，不修改偏好或恢复会话。
// mouse/screens 使用 AppKit 左下原点；CGWindow bounds 使用 Quartz 左上原点。
private struct SessionSnapshot: Decodable {
    let mainPID: Int32
    let mainIdentity: String
    let userID: UInt32
    let phase: String
}

private struct PointSnapshot: Encodable {
    let x: Double
    let y: Double
}

private struct RectSnapshot: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

private struct WindowSnapshot: Encodable {
    let name: String
    let bounds: RectSnapshot
    let onScreen: Bool
    let layer: Int
}

private struct StatusSnapshot: Encodable {
    let phase: String
    let pid: Int32
    let mouse: PointSnapshot
    let screens: [RectSnapshot]
    let windows: [WindowSnapshot]
}

/// 除 PID 外核对会话中的开始时间，避免旧 PID 被别的应用复用时泄漏其窗口信息。
private func ownerMatches(_ session: SessionSnapshot) -> Bool {
    guard session.mainPID > 0, session.userID == getuid() else { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(session.mainPID, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_uid == session.userID else { return false }
    return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)" == session.mainIdentity
}

private func windows(for session: SessionSnapshot) -> [WindowSnapshot] {
    guard ownerMatches(session),
          let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return records.compactMap { record in
        guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == session.mainPID,
              let bounds = record[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func number(_ key: String) -> Double { (bounds[key] as? NSNumber)?.doubleValue ?? 0 }
        let rect = CGRect(x: number("X"), y: number("Y"), width: number("Width"), height: number("Height"))
        return WindowSnapshot(name: record[kCGWindowName as String] as? String ?? "",
                              bounds: RectSnapshot(rect),
                              onScreen: (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                              layer: (record[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
    }
}

@MainActor
private func readStatus(dataDirectory: URL) throws -> StatusSnapshot {
    let sessionURL = dataDirectory.appendingPathComponent("NativeDockRecovery/current-session.plist")
    let session = try PropertyListDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: sessionURL))
    let mouse = NSEvent.mouseLocation
    return StatusSnapshot(phase: session.phase, pid: session.mainPID,
                          mouse: PointSnapshot(x: mouse.x, y: mouse.y),
                          screens: NSScreen.screens.map { RectSnapshot($0.frame) },
                          windows: windows(for: session))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print("用法：DockSessionStatus [数据目录]；默认读取当前工作目录下的 Data。输出只读 JSON，不启动主应用。")
    exit(0)
}
guard arguments.count <= 1 else {
    try? FileHandle.standardError.write(contentsOf: Data("只接受一个数据目录参数。\n".utf8))
    exit(2)
}
let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let dataDirectory = arguments.first.map { URL(fileURLWithPath: $0, relativeTo: currentDirectory).standardizedFileURL }
    ?? currentDirectory.appendingPathComponent("Data", isDirectory: true)
do {
    let snapshot = try readStatus(dataDirectory: dataDirectory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(snapshot)
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
} catch {
    // 不输出恢复会话内容或其他进程信息。
    try? FileHandle.standardError.write(contentsOf: Data("无法读取 Dock 只读状态：\(error.localizedDescription)\n".utf8))
    exit(1)
}
