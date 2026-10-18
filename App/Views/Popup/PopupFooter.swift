import CloudreveSync
import SwiftUI

/// 弹窗底部：同步状态与「在 Finder 中打开」。
struct PopupFooter: View {
    @Environment(DriveManager.self) private var driveManager

    var body: some View {
        HStack(spacing: 6) {
            switch FooterStatus(driveManager: driveManager) {
            case .syncing(let count):
                ProgressView()
                    .controlSize(.small)
                Text("正在同步 \(count) 个文件…")
            case .problem(let symbol, let color, let text):
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(text)
                    .lineLimit(1)
            case .idle:
                Text("当前没有传输")
                    .foregroundStyle(.secondary)
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

/// 底栏状态。范围与传输列表一致（选中的云盘，未选中时全部云盘）。
///
/// 进行中的传输数只说明有没有正在传的文件，不能证明同步成功，因此无传输时只陈述事实，不宣称「已是最新」。
/// 同步不可用或降级的状态优先于传输进度：凭证失效 > 文件提供程序未启用 > 推送中断。
private enum FooterStatus {
    case syncing(Int)
    case problem(symbol: String, color: Color, text: String)
    case idle

    @MainActor
    init(driveManager: DriveManager) {
        let drives = driveManager.drives.filter { driveManager.selectedDriveID == nil || $0.id == driveManager.selectedDriveID }
        if let text = Self.describe(drives.filter { $0.status == .credentialExpired }, issue: String(localized: "需要重新登录")) {
            self = .problem(symbol: "exclamationmark.triangle.fill", color: DriveStatus.credentialExpired.indicatorColor, text: text)
        } else if let text = Self.describe(
            drives.filter { driveManager.disabledDriveIDs.contains($0.id) }, issue: String(localized: "未启用文件提供程序")
        ) {
            self = .problem(symbol: "exclamationmark.triangle.fill", color: .orange, text: text)
        } else if let text = Self.describe(drives.filter { $0.status == .eventPushLost }, issue: String(localized: "推送中断，定期同步")) {
            self = .problem(symbol: "bolt.horizontal.circle", color: DriveStatus.eventPushLost.indicatorColor, text: text)
        } else if driveManager.runningCount > 0 {
            self = .syncing(driveManager.runningCount)
        } else {
            self = .idle
        }
    }

    /// 单个云盘带名称；多个云盘给出数量。没有受影响的云盘返回 nil。
    private static func describe(_ affected: [DriveSummary], issue: String) -> String? {
        switch affected.count {
        case 0: nil
        case 1: String(localized: "「\(affected[0].name)」\(issue)")
        default: String(localized: "\(affected.count) 个云盘\(issue)")
        }
    }
}
