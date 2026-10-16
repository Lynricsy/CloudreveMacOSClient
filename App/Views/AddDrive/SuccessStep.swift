import SwiftUI

/// 完成：可直接在 Finder 中打开云盘。
struct SuccessStep: View {
    let driveID: String
    let isReauthorization: Bool

    @Environment(DriveManager.self) private var driveManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            if isReauthorization {
                Text("已重新登录")
                    .font(.title2.bold())
                Text("云盘将继续同步。")
                    .foregroundStyle(.secondary)
            } else {
                Text("云盘已添加")
                    .font(.title2.bold())
                Text("云盘已出现在 Finder 侧栏的「位置」中，文件将按需下载。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            HStack {
                Button("在 Finder 中打开") {
                    Task { await driveManager.openInFinder(id: driveID) }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .actionErrorAlert(driveManager)
    }
}
