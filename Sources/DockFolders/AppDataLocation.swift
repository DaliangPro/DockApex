import Foundation

/// 数据目录（分组、固定项、偏好、诊断与恢复记录）。
/// 从项目构建的开发版在 Info.plist 里带 WorkspaceRoot，用项目里的 Data/；安装包里的应用不带它，
/// 用 ~/Library/Application Support/DockApex/，应用包放在哪里都能用。
enum AppDataLocation {
    static var workspaceRoot: URL? {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "WorkspaceRoot") as? String, root.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    static var dataDirectory: URL {
        if let workspaceRoot { return workspaceRoot.appendingPathComponent("Data", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockApex", isDirectory: true)
    }

    static var diagnosticsDirectory: URL { dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true) }
}
