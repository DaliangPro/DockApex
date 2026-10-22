import CoreGraphics
import Darwin
import Foundation

private final class MemoryRegionAPI: DockSystemRegionAccess {
    var value: DockSystemRegionValue
    var sets = 0
    var beforeSet: (() throws -> Void)?
    var failAfterSet = false
    init(_ value: DockSystemRegionValue) { self.value = value }
    func read() throws -> DockSystemRegionValue { value }
    func set(_ value: DockSystemRegionValue) throws {
        try beforeSet?()
        self.value = value; sets += 1
        if failAfterSet { throw DockSystemRegionError.message("离线模拟 setter 之后退出") }
    }
}

@main
enum DockSystemRegionChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ text: String) throws {
            guard value else { throw DockSystemRegionError.message("预留区离线检查失败：\(text)") }
            checks += 1
        }
        let baseline = DockSystemRegionValue(rect: .zero, reason: 0, orientation: 2)
        let requested = try DockSystemRegionValue.bottom(appKitRect: CGRect(x: 1012, y: -1329, width: 2056, height: 57), primaryHeight: 1692)
        try check(requested.rect == CGRect(x: 1012, y: 2964, width: 2056, height: 57), "下方副屏 AppKit 转 Quartz")
        let above = try DockSystemRegionValue.bottom(appKitRect: CGRect(x: -700, y: 1692, width: 700, height: 57), primaryHeight: 1692)
        try check(above.x == -700 && above.y == -57, "左上副屏负坐标保持")
        try check(requested.reason == 5 && requested.orientation == 2, "仅使用本机已验证底部接口常量")
        let secondary = CGRect(x: 1012, y: -1329, width: 2056, height: 1329)
        let left = try DockSystemRegionValue.reservation(screenFrame: secondary,
            reservedFrame: CGRect(x: 1012, y: -1329, width: 57, height: 1329), primaryHeight: 1692, edge: .left)
        let right = try DockSystemRegionValue.reservation(screenFrame: secondary,
            reservedFrame: CGRect(x: 3011, y: -1329, width: 57, height: 1329), primaryHeight: 1692, edge: .right)
        try check(left.rect == CGRect(x: 1012, y: 1692, width: 57, height: 1329) && left.orientation == 3, "副屏左侧完整边缘及方向")
        try check(right.rect == CGRect(x: 3011, y: 1692, width: 57, height: 1329) && right.orientation == 4, "副屏右侧完整边缘及方向")
        let topLeftScreen = CGRect(x: -800, y: 1692, width: 800, height: 600)
        let topLeft = try DockSystemRegionValue.reservation(screenFrame: topLeftScreen,
            reservedFrame: CGRect(x: -800, y: 1692, width: 57, height: 600), primaryHeight: 1692, edge: .left)
        try check(topLeft.rect == CGRect(x: -800, y: -600, width: 57, height: 600), "左上副屏侧边负坐标转换")
        for (rectangle, edge) in [
            (CGRect(x: 1012, y: -1329, width: 2057, height: 57), DockSystemRegionEdge.bottom),
            (CGRect(x: 1012, y: -1328, width: 2056, height: 57), .bottom),
            (CGRect(x: 1012, y: -1329, width: 2056, height: 300), .bottom),
            (CGRect(x: 1012, y: -1329, width: 57, height: 1328), .left),
            (CGRect(x: 1013, y: -1329, width: 57, height: 1329), .left),
            (CGRect(x: 3010, y: -1329, width: 57, height: 1329), .right),
            (CGRect(x: 1012, y: -1329, width: 500, height: 1329), .left),
            (CGRect(x: 1012, y: -1329, width: 0, height: 1329), .left)
        ] {
            var rejected = false
            do { _ = try DockSystemRegionValue.reservation(screenFrame: secondary, reservedFrame: rectangle, primaryHeight: 1692, edge: edge) }
            catch { rejected = true }
            try check(rejected, "拒绝跨屏、悬浮、过厚、非完整边缘或空预留区")
        }
        try check(baseline.isValid, "自动隐藏的零区域可恢复")
        let nan = DockSystemRegionValue(rect: CGRect(x: Double.nan, y: 0, width: 10, height: 10), reason: 5, orientation: 2)
        try check(!nan.isValid, "拒绝非有限坐标")
        guard let owner = DockSystemRegionOwner.capture(getpid()) else { throw DockSystemRegionError.message("无法验证检查进程身份") }
        try check(owner.isAlive, "当前 PID UID 出生身份匹配")
        var reused = owner; reused.seconds += 1
        try check(!reused.isAlive, "PID 复用不能冒认主进程")
        var otherUser = owner; otherUser.uid &+= 1
        try check(!otherUser.isAlive, "其他用户不能认领会话")

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/region-checks-\(UUID().uuidString)", isDirectory: true)
        let location = DockSystemRegionRecovery.Location(dataDirectory: directory)
        let api = MemoryRegionAPI(baseline)
        var session = DockSystemRegionSession(id: UUID(), owner: owner, original: baseline, restoreTarget: baseline,
                                             phase: .prepared, updatedAt: Date())
        try DockSystemRegionRecovery.withLock(at: location) {
            try DockSystemRegionRecovery.save(session, location)
            let roundtrip = try DockSystemRegionRecovery.load(location)
            try check(roundtrip.id == session.id && roundtrip.original == baseline && roundtrip.owner == owner, "完整会话往返")
            api.beforeSet = {
                let persisted = try DockSystemRegionRecovery.load(location)
                try check(persisted.pending == requested && persisted.applied == nil, "setter 前持久化意图")
            }
            try DockSystemRegionRecovery.apply(requested, displayUUID: "internal", session: &session, location: location, api: api)
            api.beforeSet = nil
            try check(api.sets == 1 && session.phase == .active && session.pending == nil && session.applied == requested, "成功后才提交 active")
            try check(session.original == baseline && session.restoreTarget == baseline, "保留完整原 getter")
            let didRestore = try DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: api)
            try check(didRestore && api.value == baseline, "只还原仍属本工具的应用值")
            let again = try DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: api)
            try check(!again && api.sets == 2, "恢复幂等")

            session.id = UUID(); session.phase = .prepared; session.applied = nil
            api.value = baseline; api.failAfterSet = true
            do { try DockSystemRegionRecovery.apply(requested, displayUUID: "internal", session: &session, location: location, api: api) }
            catch { }
            api.failAfterSet = false
            let pending = try DockSystemRegionRecovery.load(location)
            try check(pending.pending == requested && pending.applied == nil, "setter 后异常仍有意图记录")
            try check(try DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: api), "写后崩溃可条件恢复")
            try check(api.value == baseline, "写后崩溃恢复零区域")

            session.id = UUID(); session.phase = .prepared; session.applied = nil; session.pending = nil
            try DockSystemRegionRecovery.apply(requested, displayUUID: "internal", session: &session, location: location, api: api)
            var external = requested; external.height = 31
            api.value = external
            let countBefore = api.sets
            try check(try !DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: api), "原生 Dock 后写的值不覆盖")
            try check(api.value == external && api.sets == countBefore, "保留系统竞争结果")

            session.id = UUID(); session.phase = .active; session.applied = requested; session.pending = nil
            try DockSystemRegionRecovery.save(session, location)
            try check(try !DockSystemRegionRecovery.restoreLocked(location, expectedID: UUID(), api: api), "旧助手 UUID 不能恢复新会话")
            try DockSystemRegionRecovery.apply(requested, displayUUID: "internal", session: &session, location: location, api: api)
            try check(session.restoreTarget == external && session.original == baseline, "事件重申请保留最新系统值及初始备份")
            try check(try DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: api), "重申请后恢复最新系统值")
            try check(api.value == external, "恢复目标不倒退到旧屏幕布局")

            session.id = UUID(); session.phase = .prepared; session.applied = nil; session.pending = nil
            api.value = baseline
            try DockSystemRegionRecovery.apply(left, displayUUID: "internal", session: &session, location: location, api: api)
            try DockSystemRegionRecovery.apply(right, displayUUID: "internal", session: &session, location: location, api: api)
            try check(session.restoreTarget == baseline && api.value == right, "左右切换不把中途自有区域当作系统原值")
            try check(try DockSystemRegionRecovery.restoreLocked(location, expectedID: session.id, api: api), "右侧占位可完整恢复")
            try check(api.value == baseline, "恢复侧边占位保留原方向及完整空区域")
        }
        print("系统 Dock 预留区离线检查 \(checks) 项通过；未连接 SkyLight、未写入系统区域。")
    }
}
