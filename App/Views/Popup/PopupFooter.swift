import SwiftUI

/// 弹窗底部：同步状态与「在 Finder 中打开」。
struct PopupFooter: View {
    @Environment(DriveManager.self) private var driveManager

    var body: some View {
        HStack(spacing: 6) {
            if driveManager.runningCount > 0 {
                ProgressView()
                    .controlSize(.small)
                Text("正在同步 \(driveManager.runningCount) 个文件…")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("文件已是最新")
            }
            Spacer()
            Button("在 Finder 中打开") {
                Task { await driveManager.openPreferredInFinder() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
