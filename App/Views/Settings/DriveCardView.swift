import SwiftUI

/// 设置中的单个云盘卡片：名称、站点、状态、容量与操作菜单。
struct DriveCardView: View {
    let drive: DriveSummary

    @State private var isEditingIgnoreRules = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(drive.name)
                    .font(.headline)
                Text(drive.siteURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let email = drive.userEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    DriveStatusDot(status: drive.status)
                    Text(drive.status.displayText)
                        .font(.caption)
                }
                DriveCapacityView(used: drive.capacityUsed, total: drive.capacityTotal)
            }
            Spacer(minLength: 0)
            DriveCardMenu(
                drive: drive, isEditingIgnoreRules: $isEditingIgnoreRules, isConfirmingRemoval: $isConfirmingRemoval
            )
        }
        .padding(.vertical, 6)
        .modifier(DriveActionDialogs(
            drive: drive, isEditingIgnoreRules: $isEditingIgnoreRules, isConfirmingRemoval: $isConfirmingRemoval
        ))
    }
}
