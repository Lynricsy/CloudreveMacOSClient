import AppKit
import CloudreveAPI
import SwiftUI

/// 「通用」设置页。
struct GeneralSettingsView: View {
    @Bindable var preferences: GeneralPreferences

    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("通知") {
                Toggle("凭证过期时通知", isOn: $preferences.notifyCredentialExpired)
                Toggle("文件冲突时通知", isOn: $preferences.notifyFileConflict)
            }
            Section {
                Picker("日志级别", selection: $preferences.logLevel) {
                    Text("调试").tag(LogLevel.debug)
                    Text("信息").tag(LogLevel.info)
                    Text("错误").tag(LogLevel.error)
                }
                Button("打开日志") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                }
            } header: {
                Text("日志")
            } footer: {
                Text("日志级别重启后生效。在「控制台」中搜索 plus.ling.cloudreve 查看日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    /// 与系统状态一致时不处理（包括失败后回拨开关引起的再次回调，避免清掉错误提示）。
    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = String(localized: "无法更改登录时启动：\(error.localizedDescription)")
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
