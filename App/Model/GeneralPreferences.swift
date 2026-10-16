import CloudreveAPI
import CloudreveSync
import Foundation
import Observation

/// 「通用」设置：包装共享库 `app_setting` 表中的键，修改即写回（扩展进程也读同一张表）。
@MainActor
@Observable
final class GeneralPreferences {
    static let notifyCredentialExpiredKey = "notify_credential_expired"
    static let notifyFileConflictKey = "notify_file_conflict"
    static let logLevelKey = AppSettings.logLevelKey
    static let launchAtLoginInitializedKey = "launch_at_login_initialized"

    @ObservationIgnored private let settings: AppSettings

    /// 凭证过期时发送通知（默认开）。
    var notifyCredentialExpired: Bool {
        didSet { persist(Self.notifyCredentialExpiredKey, String(notifyCredentialExpired)) }
    }

    /// 文件冲突时发送通知（默认开）。
    var notifyFileConflict: Bool {
        didSet { persist(Self.notifyFileConflictKey, String(notifyFileConflict)) }
    }

    /// 日志级别（App 与扩展重启后生效）。
    var logLevel: LogLevel {
        didSet { persist(Self.logLevelKey, logLevel.rawValue) }
    }

    init(settings: AppSettings) {
        self.settings = settings
        notifyCredentialExpired = (try? settings.bool(Self.notifyCredentialExpiredKey, default: true)) ?? true
        notifyFileConflict = (try? settings.bool(Self.notifyFileConflictKey, default: true)) ?? true
        logLevel = settings.logLevel
    }

    /// 是否已做过首次启动的「登录时启动」注册。
    var launchAtLoginInitialized: Bool {
        (try? settings.get(Self.launchAtLoginInitializedKey)) != nil
    }

    func markLaunchAtLoginInitialized() {
        persist(Self.launchAtLoginInitializedKey, "true")
    }

    private func persist(_ key: String, _ value: String) {
        do {
            try settings.set(key, value)
        } catch {
            Log.shared.error("Preferences", "写入设置 \(key) 失败：\(error.localizedDescription)")
        }
    }
}
