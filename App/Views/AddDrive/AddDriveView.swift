import SwiftUI

/// 「添加云盘」/「重新登录」窗口（470×630）。
struct AddDriveView: View {
    let request: AddDriveRequest

    @Environment(DriveManager.self) private var driveManager
    @State private var model: AddDriveViewModel?

    var body: some View {
        VStack(spacing: 24) {
            AddDriveHeader(isReauthorizing: request.reauthorizeDriveID != nil)
            if let model {
                AddDriveStepContent(model: model)
            } else {
                Spacer()
            }
        }
        .padding(32)
        .frame(width: 470, height: 630)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            if model == nil {
                model = AddDriveViewModel(request: request, driveManager: driveManager)
            }
        }
    }
}
