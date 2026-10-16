import SwiftUI

/// 以 alert 展示 `DriveManager.actionError`。
struct ActionErrorAlert: ViewModifier {
    @Bindable var driveManager: DriveManager

    func body(content: Content) -> some View {
        content.alert("操作失败", isPresented: $driveManager.isShowingActionError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(driveManager.actionError ?? "")
        }
    }
}

extension View {
    func actionErrorAlert(_ driveManager: DriveManager) -> some View {
        modifier(ActionErrorAlert(driveManager: driveManager))
    }
}
