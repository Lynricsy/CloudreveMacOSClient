import SwiftUI

/// 失败：显示错误并允许重试。
struct FailureStep: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("出错了")
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Spacer()
            HStack {
                Spacer()
                Button("重试", action: onRetry)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
