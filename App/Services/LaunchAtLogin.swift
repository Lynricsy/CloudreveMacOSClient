import CloudreveAPI
import Foundation
import ServiceManagement

/// 「登录时启动」：`SMAppService.mainApp` 注册/注销主 App。
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 切换开机自启；目标状态与当前一致时不做任何事。
    static func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 首次启动默认开启（与 Windows 版默认开机自启一致），只做一次。
    static func initializeOnFirstLaunch(preferences: GeneralPreferences) {
        guard !preferences.launchAtLoginInitialized else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            Log.shared.error("LaunchAtLogin", "首次注册登录时启动失败：\(error.localizedDescription)")
        }
        preferences.markLaunchAtLoginInitialized()
    }
}
