import SwiftUI

/// 尚未添加任何云盘时的整页空态。
struct PopupEmptyState: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("还没有云盘", systemImage: "externaldrive.badge.plus")
        } description: {
            Text("添加一个 Cloudreve 云盘，即可在 Finder 中访问和同步文件。")
        } actions: {
            Button("添加云盘") {
                WindowRouter.present(AddDriveRequest(), using: openWindow)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }
}
