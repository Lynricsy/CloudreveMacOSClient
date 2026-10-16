import SwiftUI

/// 菜单栏弹窗（370×530）：顶部栏、云盘筛选、任务列表、底部状态。
struct PopupView: View {
    let windowRouter: WindowRouter

    @Environment(DriveManager.self) private var driveManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            PopupHeader()
            Divider()
            if driveManager.drives.isEmpty {
                PopupEmptyState()
            } else {
                DriveChipsRow()
                Divider()
                TransferListView()
                Divider()
                PopupFooter()
            }
        }
        .onAppear {
            windowRouter.register(openWindow)
            driveManager.startPopupPolling()
        }
        .onDisappear { driveManager.stopPopupPolling() }
        .actionErrorAlert(driveManager)
    }
}
