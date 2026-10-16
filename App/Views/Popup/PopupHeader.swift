import AppKit
import SwiftUI

/// 弹窗顶部：Logo、名称与齿轮菜单（替代 Windows 版托盘右键菜单）。
struct PopupHeader: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(verbatim: "Cloudreve")
                .font(.headline)
            Spacer()
            Menu {
                Button("添加云盘…") {
                    WindowRouter.present(AddDriveRequest(), using: openWindow)
                }
                Button("设置…") {
                    NSApplication.shared.activate()
                    openSettings()
                }
                Divider()
                Button("退出 Cloudreve") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Label("更多", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
