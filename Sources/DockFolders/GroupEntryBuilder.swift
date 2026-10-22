import AppKit
import CryptoKit
import Security

@MainActor
final class GroupEntryBuilder {
    private let entriesDirectory: URL
    private let proxyExecutable: URL
    private let mainAppURL: URL

    init(entriesDirectory: URL, proxyExecutable: URL, mainAppURL: URL) {
        self.entriesDirectory = entriesDirectory
        self.proxyExecutable = proxyExecutable
        self.mainAppURL = mainAppURL
    }

    func build(group: AppGroup) throws -> URL {
        let files = FileManager.default
        // 路径由不可变分组 ID 决定，改名、排序和增减应用不改变 Dock 固定目标。
        let appURL = entriesDirectory.appendingPathComponent(group.id.uuidString + ".app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(group)
        let executableData = try Data(contentsOf: proxyExecutable)
        let executableDigest = SHA256.hash(data: executableData).map { String(format: "%02x", $0) }.joined()
        let infoURL = contents.appendingPathComponent("Info.plist")
        if let previous = try? Data(contentsOf: infoURL),
           let info = try? PropertyListSerialization.propertyList(from: previous, format: nil) as? [String: Any],
           info["DockFoldersGroupSnapshot"] as? Data == snapshot,
           info["DockFoldersMainAppPath"] as? String == mainAppURL.path,
           info["DockFoldersEntryProtocol"] as? Int == 2,
           info["LSUIElement"] as? Bool == true,
           info["DockFoldersProxySHA256"] as? String == executableDigest,
           files.fileExists(atPath: resources.appendingPathComponent("GroupIcon.icns").path),
           signatureIsValid(at: appURL) {
            return appURL
        }
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("GroupEntry")
        // 原地原子写入已编译代理，避免依赖安装或对用户应用做任何修改。
        try executableData.write(to: executable, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let identifier = "local.dockfolders.group." + group.id.uuidString.lowercased()
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": group.name,
            "CFBundleDisplayName": group.name,
            "CFBundleExecutable": "GroupEntry",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "2",
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleIconFile": "GroupIcon",
            "LSMinimumSystemVersion": "14.0",
            // 固定入口保留在原生 Dock；后台代理不再成为常规 App 或抢占菜单栏。
            "LSUIElement": true,
            "DockFoldersMainAppPath": mainAppURL.path,
            "DockFoldersGroupID": group.id.uuidString,
            "DockFoldersGroupSnapshot": snapshot,
            "DockFoldersEntryProtocol": 2,
            "DockFoldersProxySHA256": executableDigest
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try iconData(apps: group.apps).write(to: resources.appendingPathComponent("GroupIcon.icns"), options: .atomic)
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"), options: .atomic)
        try files.setAttributes([.modificationDate: Date()], ofItemAtPath: appURL.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, appURL.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        if sign.terminationStatus != 0 { throw EntryBuildError.signingFailed(sign.terminationStatus) }
        return appURL
    }

    private func signatureIsValid(at url: URL) -> Bool {
        // 分组包签名会改变 Mach-O 的签名区，不能再与签名前模板逐字节比较。
        // 输入模板摘要用于判断构建版本，本包签名则核验已签名的执行文件和资源。
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    private func iconData(apps: [AppReference]) throws -> Data {
        // ICNS 使用 PNG 图块，包含普通及 Retina 尺寸，系统负责缩放显示。
        var elements = Data()
        let types: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
        for (type, pixels) in types {
            let image = makeIcon(apps: apps, size: pixels)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw EntryBuildError.iconFailed }
            elements.append(Data(type.utf8))
            elements.append(bigEndian: UInt32(png.count + 8))
            elements.append(png)
        }
        var result = Data("icns".utf8)
        result.append(bigEndian: UInt32(elements.count + 8))
        result.append(elements)
        return result
    }

    private func makeIcon(apps: [AppReference], size: Int) -> NSImage {
        let dimension = CGFloat(size)
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = NSRect(x: dimension * 0.07, y: dimension * 0.07, width: dimension * 0.86, height: dimension * 0.86)
        let shape = NSBezierPath(roundedRect: rect, xRadius: dimension * 0.20, yRadius: dimension * 0.20)
        NSColor(calibratedRed: 0.76, green: 0.81, blue: 0.87, alpha: 1).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        shape.lineWidth = max(1, dimension * 0.012)
        shape.stroke()
        let shown = Array(apps.prefix(9))
        let count = shown.count
        let grid = count <= 4 ? 2 : 3
        let cell = dimension * (grid == 2 ? 0.32 : 0.225)
        let spacing = dimension * 0.035
        let total = CGFloat(grid) * cell + CGFloat(grid - 1) * spacing
        let origin = (dimension - total) / 2
        for (index, app) in shown.enumerated() {
            let column = index % grid
            let row = index / grid
            let cellRect = NSRect(x: origin + CGFloat(column) * (cell + spacing),
                                  y: dimension - origin - cell - CGFloat(row) * (cell + spacing), width: cell, height: cell)
            NSWorkspace.shared.icon(forFile: app.path).draw(in: cellRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        if shown.isEmpty, let symbol = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil) {
            symbol.draw(in: rect.insetBy(dx: dimension * 0.18, dy: dimension * 0.18), from: .zero, operation: .sourceOver, fraction: 0.7)
        }
        return image
    }
}

private enum EntryBuildError: LocalizedError {
    case signingFailed(Int32)
    case iconFailed
    var errorDescription: String? {
        switch self {
        case .signingFailed(let code): "分组入口本地签名失败（\(code)）。"
        case .iconFailed: "无法生成分组图标。"
        }
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
