import AppKit
import SwiftUI

/// 云盘卡片右侧的操作菜单。
struct DriveCardMenu: View {
    let drive: DriveSummary
    @Binding var isEditingIgnoreRules: Bool
    @Binding var isConfirmingRemoval: Bool

    @Environment(DriveManager.self) private var driveManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button("在 Finder 中打开") {
                Task { await driveManager.openInFinder(id: drive.id) }
            }
            Button("打开网站") {
                NSWorkspace.shared.open(drive.siteURL)
            }
            Button("立即同步") {
                Task { await driveManager.syncNow(id: drive.id) }
            }
            Divider()
            Button("重新登录…") {
                WindowRouter.present(AddDriveRequest(reauthorizeDriveID: drive.id), using: openWindow)
            }
            Button("忽略规则…") {
                isEditingIgnoreRules = true
            }
            Divider()
            Button("移除…", role: .destructive) {
                isConfirmingRemoval = true
            }
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
