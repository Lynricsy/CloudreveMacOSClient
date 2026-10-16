import SwiftUI

/// 添加云盘窗口顶部：Logo 与标题。
struct AddDriveHeader: View {
    let isReauthorizing: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            if isReauthorizing {
                Text("重新登录云盘")
                    .font(.title2.bold())
            } else {
                Text("添加云盘")
                    .font(.title2.bold())
            }
        }
        .padding(.top, 16)
    }
}
