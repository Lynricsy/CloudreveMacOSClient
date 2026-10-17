import SwiftUI

/// 只有一个云盘时的设置页：放大的头部、占满宽度的容量卡片与账号概览网格。
struct DriveDashboardView: View {
    let drive: DriveSummary

    @Environment(DriveManager.self) private var driveManager
    @State private var isEditingIgnoreRules = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        let state = driveManager.overviews[drive.id] ?? DriveOverviewState()
        VStack(alignment: .leading, spacing: 18) {
            DriveDashboardHeader(
                drive: drive, nickname: state.overview?.user.nickname,
                isEditingIgnoreRules: $isEditingIgnoreRules, isConfirmingRemoval: $isConfirmingRemoval
            )
            CapacityCard(used: drive.capacityUsed, total: drive.capacityTotal, updatedAt: drive.capacityUpdatedAt)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("概览")
                        .font(.headline)
                    Spacer()
                    if state.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await driveManager.loadOverview(id: drive.id, force: true) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("刷新")
                    }
                }
                if let message = state.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                AccountStatsGrid(drive: drive, overview: state.overview)
                    .redacted(reason: state.overview == nil && state.isLoading ? .placeholder : [])
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: drive.id) {
            await driveManager.loadOverview(id: drive.id, force: false)
        }
        .modifier(DriveActionDialogs(
            drive: drive, isEditingIgnoreRules: $isEditingIgnoreRules, isConfirmingRemoval: $isConfirmingRemoval
        ))
    }
}
