import SwiftUI

/// 「云盘」设置页：单云盘显示概览，多云盘每个一张卡片；底部添加按钮。
struct DrivesSettingsView: View {
    @Environment(DriveManager.self) private var driveManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if driveManager.drives.isEmpty {
                ContentUnavailableView(
                    "还没有云盘", systemImage: "externaldrive.badge.plus",
                    description: Text("添加一个 Cloudreve 云盘，即可在 Finder 中访问和同步文件。")
                )
                // 与概览分支的 ScrollView 一样占满高度，底部按钮栏才会贴底
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if driveManager.drives.count == 1, let drive = driveManager.drives.first {
                ScrollView {
                    DriveDashboardView(drive: drive)
                }
            } else {
                List(driveManager.drives) { drive in
                    DriveCardView(drive: drive)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Spacer()
                Button("添加云盘…") {
                    WindowRouter.present(AddDriveRequest(), using: openWindow)
                }
            }
            .padding(12)
        }
    }
}
