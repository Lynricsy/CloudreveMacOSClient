import AppKit
import CloudreveAPI
import Foundation
import UserNotifications

/// 应用委托：持有全局状态，接收 `cloudreve://` 回跳与通知点击。
///
/// 不使用 `.onOpenURL`：MenuBarExtra 的内容视图在弹窗未打开时不存在，URL 会丢失。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let driveManager = DriveManager()
    let windowRouter = WindowRouter()
    private var poller: ActivityPoller?

    /// 通知中心委托必须在启动完成前设置，否则冷启动时点击通知的回调会丢失。
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OSLogSink.install(minimum: driveManager.preferences.logLevel)
        LaunchAtLogin.initializeOnFirstLaunch(preferences: driveManager.preferences)
        let poller = ActivityPoller(
            driveStore: driveManager.driveStore, transferStore: driveManager.transferStore, preferences: driveManager.preferences
        )
        poller.start()
        self.poller = poller
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            OAuthFlow.shared.handleExternalCallback(url)
        }
    }

    /// 点击「需要重新登录」通知 → 打开该云盘的重新登录窗口。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let driveID = response.notification.request.content.userInfo[NotificationService.driveIDKey] as? String
        guard let driveID else { return }
        await showReauthorization(driveID: driveID)
    }

    /// App 在前台时也显示横幅。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func showReauthorization(driveID: String) {
        guard driveManager.drive(id: driveID) != nil else { return }
        windowRouter.show(AddDriveRequest(reauthorizeDriveID: driveID))
    }
}
