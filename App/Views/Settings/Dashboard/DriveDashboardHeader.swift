import SwiftUI

/// 单云盘概览顶部：图标、名称、账号、站点、状态与操作菜单。
struct DriveDashboardHeader: View {
    let drive: DriveSummary
    let nickname: String?
    @Binding var isEditingIgnoreRules: Bool
    @Binding var isConfirmingRemoval: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(drive.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(accountLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Link(drive.siteURL.absoluteString, destination: drive.siteURL)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                DriveStatusDot(status: drive.status)
                Text(drive.status.displayText)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: .capsule)
            DriveCardMenu(
                drive: drive, isEditingIgnoreRules: $isEditingIgnoreRules, isConfirmingRemoval: $isConfirmingRemoval
            )
            .controlSize(.large)
        }
    }

    /// 「昵称 · 邮箱」，缺哪个省哪个。
    private var accountLine: String {
        [nickname, drive.userEmail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
