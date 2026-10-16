import SwiftUI

/// 任务列表：「正在同步」与「最近」两组。
struct TransferListView: View {
    @Environment(DriveManager.self) private var driveManager

    var body: some View {
        List {
            if !driveManager.runningTransfers.isEmpty {
                Section("正在同步") {
                    ForEach(driveManager.runningTransfers) { row in
                        TransferRowView(row: row)
                    }
                }
            }
            if !driveManager.recentTransfers.isEmpty {
                Section("最近") {
                    ForEach(driveManager.recentTransfers) { row in
                        TransferRowView(row: row)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if driveManager.runningTransfers.isEmpty && driveManager.recentTransfers.isEmpty {
                ContentUnavailableView("暂无最近活动", systemImage: "clock")
            }
        }
    }
}
