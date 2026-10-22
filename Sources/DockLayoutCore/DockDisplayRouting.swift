import Foundation

enum DockDisplayRouting {
    /// 指定显示器暂时离线时只回退显示，不覆盖用户保存的 UUID，重新连接后自动回到原屏。
    static func resolvedUUIDs(mode: DockDisplayMode, requestedUUID: String?,
                              availableUUIDs: [String], primaryUUID: String?) -> [String] {
        let available = availableUUIDs.reduce(into: [String]()) { result, uuid in
            if !result.contains(uuid) { result.append(uuid) }
        }
        guard let fallback = primaryUUID.flatMap({ available.contains($0) ? $0 : nil }) ?? available.first else { return [] }
        switch mode {
        case .all: return available
        case .specific:
            return [requestedUUID.flatMap({ available.contains($0) ? $0 : nil }) ?? fallback]
        case .primary, .followPointer: return [fallback]
        }
    }
}
