import AppKit
import CryptoKit

/// 只在指定临时目录构建代理包，既不启动应用，也不修改原生 Dock。
@main
@MainActor
struct GroupEntryBuilderChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("参数：临时目录 代理可执行文件 主应用路径")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let main = URL(fileURLWithPath: CommandLine.arguments[3])
        let builder = GroupEntryBuilder(entriesDirectory: directory, proxyExecutable: executable, mainAppURL: main)
        let group = AppGroup(id: UUID(), name: "入口协议检查", apps: [])
        let url = try builder.build(group: group)
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let firstInfo = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: firstInfo, format: nil) as! [String: Any]
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        expect(info["LSUIElement"] as? Bool == true, "预热入口必须为 agent")
        expect(info["LSBackgroundOnly"] == nil, "代理必须保留 AppKit AppleEvent 支持")
        expect(info["DockFoldersEntryProtocol"] as? Int == 2, "入口协议必须更新")
        expect(info["DockFoldersGroupID"] as? String == group.id.uuidString, "分组身份必须保留")
        expect(info["DockFoldersMainAppPath"] as? String == main.path, "必须绑定本项目主应用")
        let copiedExecutable = url.appendingPathComponent("Contents/MacOS/GroupEntry")
        let executableBytes = try Data(contentsOf: executable)
        let copiedBytes = try Data(contentsOf: copiedExecutable)
        let expectedDigest = SHA256.hash(data: executableBytes).map { String(format: "%02x", $0) }.joined()
        expect(!copiedBytes.isEmpty && info["DockFoldersProxySHA256"] as? String == expectedDigest,
               "元数据必须记录签名前源模板的摘要")
        let firstModification = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        expect(try builder.build(group: group) == url, "重复构建保留入口路径")
        let repeatedInfo = try Data(contentsOf: infoURL)
        expect(firstInfo == repeatedInfo, "重复构建不重写元数据")
        let secondModification = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        expect(firstModification == secondModification, "缓存命中不触发无效重签名")
        print("分组入口包检查 \(checks) 项通过；未启动代理或修改 Dock。")
    }
}
