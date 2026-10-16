import CloudreveAPI
import Foundation
import UserNotifications

/// 本地通知：凭证过期与文件冲突。
enum NotificationService {
    /// 凭证过期通知 `userInfo` 中的云盘 id 键；点击通知据此打开重新登录窗口。
    static let driveIDKey = "driveID"

    static func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.shared.error("Notification", "请求通知权限失败：\(error.localizedDescription)")
        }
    }

    static func notifyCredentialExpired(driveID: String, driveName: String) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "云盘「\(driveName)」需要重新登录")
        content.body = String(localized: "点击此通知重新登录，登录后将继续同步。")
        content.sound = .default
        content.userInfo = [driveIDKey: driveID]
        await deliver(identifier: "credential-expired-\(driveID)", content: content)
    }

    static func notifyConflict(transferID: String, fileName: String, message: String) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "文件冲突：\(fileName)")
        content.body = message
        content.sound = .default
        await deliver(identifier: "conflict-\(transferID)", content: content)
    }

    private static func deliver(identifier: String, content: UNMutableNotificationContent) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.shared.error("Notification", "发送通知失败：\(error.localizedDescription)")
        }
    }
}
