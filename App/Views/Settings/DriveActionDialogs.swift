import SwiftUI

/// 云盘操作菜单触发的忽略规则编辑与移除确认（卡片与单云盘概览共用）。
struct DriveActionDialogs: ViewModifier {
    let drive: DriveSummary
    @Binding var isEditingIgnoreRules: Bool
    @Binding var isConfirmingRemoval: Bool

    @Environment(DriveManager.self) private var driveManager

    func body(content: Content) -> some View {
        content
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
