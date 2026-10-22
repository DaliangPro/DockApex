import CoreServices
import Foundation

/// 监视应用所在的文件夹：卸载、移动、重装或更新应用时回报变动的路径（约 1 秒合并一次），
/// 由应用控制器核对应用栏、分组与最近使用里的引用。
@MainActor
final class InstalledApplicationsMonitor {
    var onChange: (([String]) -> Void)?
    private var stream: FSEventStreamRef?
    private var directories: [String] = []

    /// 文件夹集合没变就不重建；不存在的文件夹（如未接上的外接磁盘）跳过。
    func watch(_ next: Set<String>) {
        let sorted = next.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        guard sorted != directories else { return }
        stop()
        directories = sorted
        guard !sorted.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<InstalledApplicationsMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { monitor.onChange?(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(nil, callback, &context, sorted as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
