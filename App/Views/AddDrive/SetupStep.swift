import SwiftUI

/// 第三步：换取令牌、校验挂载目录并注册 Finder 位置。
struct SetupStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在设置云盘…")
                .font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
