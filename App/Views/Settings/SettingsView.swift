import SwiftUI

/// 设置窗口（700×500）：云盘 / 通用 / 关于。
struct SettingsView: View {
    @Environment(DriveManager.self) private var driveManager

    var body: some View {
        TabView {
            Tab("云盘", systemImage: "externaldrive") {
                DrivesSettingsView()
            }
            Tab("通用", systemImage: "gearshape") {
                GeneralSettingsView(preferences: driveManager.preferences)
            }
            Tab("关于", systemImage: "info.circle") {
                AboutView()
            }
        }
        // 可见期间持续反映扩展与事件监听写入的云盘状态（如凭证失效、推送中断）。
        .onAppear { driveManager.startPolling(for: .settings) }
        .onDisappear { driveManager.stopPolling(for: .settings) }
        .actionErrorAlert(driveManager)
    }
}
