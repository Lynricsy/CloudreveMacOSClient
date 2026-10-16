import SwiftUI

/// 菜单栏 App 入口（`LSUIElement`，无 Dock 图标）。
///
/// 全局状态由 `AppDelegate` 持有：通知回调、URL 回跳与 30 秒轮询都在委托中，需要与视图共用同一份 `DriveManager`。
@main
struct CloudreveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopupView(windowRouter: appDelegate.windowRouter)
                .environment(appDelegate.driveManager)
                .frame(width: 370, height: 530)
        } label: {
            MenuBarLabel(windowRouter: appDelegate.windowRouter)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("添加云盘", id: AddDriveRequest.windowID, for: AddDriveRequest.self) { $request in
            AddDriveView(request: request ?? AddDriveRequest())
                .environment(appDelegate.driveManager)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 470, height: 630)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(appDelegate.driveManager)
                .frame(width: 700, height: 500)
        }
    }
}
