import SwiftUI

/// 设置中的单个云盘卡片：名称、站点、状态、容量与操作菜单。
struct DriveCardView: View {
    let drive: DriveSummary

    @Environment(DriveManager.self) private var driveManager
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
        .sheet(isPresented: $isEditingIgnoreRules) {
            IgnorePatternsEditor(drive: drive)
        }
        .confirmationDialog("移除云盘「\(drive.name)」？", isPresented: $isConfirmingRemoval) {
            Button("移除", role: .destructive) {
                Task { await driveManager.removeDrive(id: drive.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后本地未上传的更改将丢失。")
        }
    }
}
