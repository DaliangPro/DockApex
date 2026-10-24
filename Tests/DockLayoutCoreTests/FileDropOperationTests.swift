import Foundation
import Testing
@testable import DockLayoutCore

/// 假的卷：路径以 /U盘 开头的在另一个卷上，/未挂载 开头的读不到卷信息，其余都在启动盘。
private func volume(_ url: URL) -> NSObject? {
    if url.path.hasPrefix("/未挂载") { return nil }
    return (url.path.hasPrefix("/U盘") ? "U盘" : "启动盘") as NSString
}

private let folder = URL(fileURLWithPath: "/Users/示例/文稿")
private let local = URL(fileURLWithPath: "/Users/示例/下载/报告.pdf")
private let external = URL(fileURLWithPath: "/U盘/照片.jpg")

private func copies(_ sources: [URL], into target: URL = folder, option: Bool = false, command: Bool = false,
                    moveAllowed: Bool = true) -> Bool {
    FileDropOperation.copies(sources, into: target, option: option, command: command, moveAllowed: moveAllowed, volume: volume)
}

@Test func `同一个卷默认移动`() {
    #expect(!copies([local]))
}

@Test func `跨卷默认拷贝，不删源文件`() {
    #expect(copies([external]))
    #expect(copies([local, external]))
}

@Test func `Option 拷贝、Command 移动、来源不许移动只能拷贝`() {
    #expect(copies([local], option: true))
    #expect(!copies([external], command: true))
    #expect(copies([local], command: true, moveAllowed: false))
}

@Test func `读不到卷信息时按拷贝处理`() {
    #expect(copies([local], into: URL(fileURLWithPath: "/未挂载/文件夹")))
    #expect(copies([URL(fileURLWithPath: "/未挂载/文件")]))
}

@Test func `真实路径：启动盘上的系统卷与数据卷算同一个卷`() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("拖入测试-\(UUID().uuidString).txt")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(!FileDropOperation.copies([file], into: FileManager.default.homeDirectoryForCurrentUser,
                                      option: false, command: false, moveAllowed: true))
    #expect(!FileDropOperation.copies([URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")],
                                      into: FileManager.default.homeDirectoryForCurrentUser, option: false, command: false, moveAllowed: true))
}
