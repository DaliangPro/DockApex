import Foundation
import Testing
@testable import DockLayoutCore

@Test func `主屏使用系统主屏而非最近获得键盘焦点的屏幕`() {
    #expect(DockDisplayRouting.resolvedUUIDs(mode: .primary, requestedUUID: nil,
                                           availableUUIDs: ["内屏", "外屏"], primaryUUID: "外屏") == ["外屏"])
}

@Test func `指定屏幕离线回退并在重连后恢复`() {
    #expect(DockDisplayRouting.resolvedUUIDs(mode: .specific, requestedUUID: "外屏",
                                           availableUUIDs: ["内屏"], primaryUUID: "内屏") == ["内屏"])
    #expect(DockDisplayRouting.resolvedUUIDs(mode: .specific, requestedUUID: "外屏",
                                           availableUUIDs: ["内屏", "外屏"], primaryUUID: "内屏") == ["外屏"])
}

@Test func `同时显示去重且不遗漏扩展屏幕`() {
    #expect(DockDisplayRouting.resolvedUUIDs(mode: .all, requestedUUID: nil,
                                           availableUUIDs: ["内屏", "外屏", "外屏"], primaryUUID: "内屏") == ["内屏", "外屏"])
    #expect(DockDisplayRouting.resolvedUUIDs(mode: .all, requestedUUID: nil,
                                           availableUUIDs: [], primaryUUID: nil).isEmpty)
}

@Test func `旧版显示偏好可读取并往返保存指定显示器`() throws {
    let data = Data(#"{"iconSize":37,"maximumIconSize":62,"magnification":true,"showRunningIndicators":true,"showRecentApplications":true,"animateLaunching":true}"#.utf8)
    var options = try JSONDecoder().decode(ShelfOptions.self, from: data)
    #expect(options.displayMode == nil)
    options.displayMode = .specific
    options.displayUUID = "550E8400-E29B-41D4-A716-446655440000"
    #expect(try JSONDecoder().decode(ShelfOptions.self, from: JSONEncoder().encode(options)) == options)
}
