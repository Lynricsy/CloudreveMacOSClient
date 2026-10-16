import AppKit
import SwiftUI

/// 第一步：输入站点地址并检查服务器。
struct SiteURLStep: View {
    @Bindable var model: AddDriveViewModel

    private var isChecking: Bool { model.step == .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("站点地址", text: $model.siteURLText, prompt: Text(verbatim: "https://cloud.example.com"))
                .textFieldStyle(.roundedBorder)
                .disabled(model.isReauthorizing || isChecking)
                .onSubmit(start)
            if model.isReauthorizing {
                Text("将在浏览器中重新登录该站点，登录的账号需与原账号一致。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("输入 Cloudreve 站点地址（需要 4.12.0 或更高版本），随后将在浏览器中登录并选择要挂载的目录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查服务器…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("继续", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
    }

    private func start() {
        guard model.canStart else { return }
        model.start(anchor: NSApplication.shared.keyWindow)
    }
}
