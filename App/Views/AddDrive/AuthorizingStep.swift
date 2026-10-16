import SwiftUI

/// 第二步：等待浏览器授权回跳。
struct AuthorizingStep: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在浏览器中授权…")
                .font(.headline)
            Text("请在打开的页面中登录并授权；新增云盘时还需在网页中选择要挂载的目录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("取消", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
    }
}
