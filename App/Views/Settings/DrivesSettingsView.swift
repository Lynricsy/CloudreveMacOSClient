import SwiftUI

/// 「云盘」设置页：每个云盘一张卡片，底部添加按钮。
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
