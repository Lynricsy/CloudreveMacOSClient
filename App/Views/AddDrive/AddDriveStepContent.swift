import SwiftUI

/// 按流程状态切换子视图。
struct AddDriveStepContent: View {
    let model: AddDriveViewModel

    var body: some View {
        switch model.step {
        case .enterURL, .checking:
            SiteURLStep(model: model)
        case .authorizing:
            AuthorizingStep(onCancel: model.cancel)
        case .settingUp:
            SetupStep()
        case .success(let driveID):
            SuccessStep(driveID: driveID, isReauthorization: model.isReauthorizing)
        case .failed(let message):
            FailureStep(message: message, onRetry: model.retry)
        }
    }
}
