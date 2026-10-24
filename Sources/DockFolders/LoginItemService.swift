import Foundation
import ServiceManagement

/// 登录时打开，与原生 Dock 一样开机就在。第一次启动时自动登记一次；之后以菜单开关和系统设置“登录项”为准，
/// 用户在那里关掉的，下次启动不再自动打开。
@MainActor
enum LoginItemService {
    private static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 返回要记进活动日志的一句话；已经处理过就返回 nil。
    static func registerOnFirstLaunch() -> String? {
        guard !UserDefaults.standard.bool(forKey: configuredKey) else { return nil }
        UserDefaults.standard.set(true, forKey: configuredKey)
        do {
            try SMAppService.mainApp.register()
            return "已登记为登录项：\(statusText)"
        } catch {
            return "登记登录项失败：\(error.localizedDescription)（\(statusText)）"
        }
    }

    /// 菜单开关。系统要求用户在“登录项”里批准时，打开那一页。
    static func toggle() throws {
        UserDefaults.standard.set(true, forKey: configuredKey)
        if isEnabled { try SMAppService.mainApp.unregister(); return }
        try SMAppService.mainApp.register()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .requiresApproval: "待在系统设置的登录项里批准"
        case .notRegistered: "未登记"
        case .notFound: "系统找不到本应用"
        @unknown default: "未知"
        }
    }
}
