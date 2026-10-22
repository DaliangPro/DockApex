import Foundation

/// 只计算新的固定项列表，不读写系统偏好。最近使用和运行项不在本模型中。
public enum DockLayout {
    /// Dock 会补写 bookmark 和日期；恢复时比较入口身份及顺序，避免误判为用户改动。
    public static func identities(_ tiles: [[String: Any]]) -> [String] {
        tiles.map { tile in
            if let url = appURL(in: tile) { return "app:" + normalizedPath(url) }
            return "other:\(tile["tile-type"] as? String ?? "unknown"):\(String(describing: tile["GUID"] ?? ""))"
        }
    }

    public static func appURL(in tile: [String: Any]) -> URL? {
        guard tile["tile-type"] as? String == "file-tile",
              let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let value = file["_CFURLString"] as? String else { return nil }
        if value.hasPrefix("file:") {
            return URL(string: value)?.standardizedFileURL.resolvingSymlinksInPath()
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        }
        return nil
    }

    public static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func newTile(url: URL, label: String, bundleIdentifier: String?) -> [String: Any] {
        var data: [String: Any] = [
            "file-data": ["_CFURLString": url.standardizedFileURL.absoluteString, "_CFURLStringType": 15],
            "file-label": label,
            "file-type": 41
        ]
        if let bundleIdentifier { data["bundle-identifier"] = bundleIdentifier }
        // 不能复制原 App 的 bookmark、签名身份或修改日期。
        return ["GUID": UInt32.random(in: 1...UInt32.max), "tile-data": data, "tile-type": "file-tile"]
    }

    public static func replacing(
        tiles: [[String: Any]],
        source: URL,
        target: URL,
        replacement: [String: Any],
        removing extraURLs: [URL] = []
    ) -> [[String: Any]] {
        let removed = Set(([source, target] + extraURLs).map(normalizedPath))
        let targetPath = normalizedPath(target)
        let sourcePath = normalizedPath(source)
        let targetIndex = tiles.firstIndex { appURL(in: $0).map(normalizedPath) == targetPath }
        let sourceIndex = tiles.firstIndex { appURL(in: $0).map(normalizedPath) == sourcePath }
        // 优先接替目标项；若源/目标只在运行区，追加一个新的常驻分组即可。
        let anchor = targetIndex ?? sourceIndex ?? tiles.endIndex
        var output: [[String: Any]] = []
        for (index, tile) in tiles.enumerated() {
            if index == anchor { output.append(replacement) }
            if let path = appURL(in: tile).map(normalizedPath), removed.contains(path) { continue }
            output.append(tile)
        }
        if anchor == tiles.endIndex { output.append(replacement) }
        return output
    }
}
