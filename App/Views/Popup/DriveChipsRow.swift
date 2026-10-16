import SwiftUI

/// 横向云盘筛选：「全部」+ 每个云盘 + 末尾添加按钮。
struct DriveChipsRow: View {
    @Environment(DriveManager.self) private var driveManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                DriveChip(isSelected: driveManager.selectedDriveID == nil, status: nil) {
                    driveManager.select(driveID: nil)
                } label: {
                    Text("全部")
                }
                ForEach(driveManager.drives) { drive in
                    DriveChip(isSelected: driveManager.selectedDriveID == drive.id, status: drive.status) {
                        driveManager.select(driveID: drive.id)
                    } label: {
                        Text(drive.name)
                    }
                }
                Button {
                    WindowRouter.present(AddDriveRequest(), using: openWindow)
                } label: {
                    Label("添加云盘", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}
