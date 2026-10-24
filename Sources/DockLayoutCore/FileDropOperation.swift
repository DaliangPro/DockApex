import Foundation

/// 把文件拖到应用栏上的文件夹，照访达与原生 Dock：同一个卷默认移动，跨卷（U 盘、网络卷、磁盘映像）默认拷贝；
/// 按住 Option 一律拷贝，按住 Command 一律移动；来源不许移动时只能拷贝。读不到卷信息时按拷贝处理，不删源文件。
/// 启动盘的系统卷与数据卷在这里是同一个卷“/”，与访达一致。
enum FileDropOperation {
    static func copies(_ sources: [URL], into folder: URL, option: Bool, command: Bool, moveAllowed: Bool,
                       volume: (URL) -> NSObject? = volumeIdentifier) -> Bool {
        if option || !moveAllowed { return true }
        if command { return false }
        guard let target = volume(folder) else { return true }
        return sources.contains { volume($0).map { !$0.isEqual(target) } ?? true }
    }

    static func volumeIdentifier(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
}
