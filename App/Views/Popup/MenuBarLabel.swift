import SwiftUI

/// 菜单栏图标（模板图像）。该视图常驻，出现时把 `openWindow` 交给 `WindowRouter`。
struct MenuBarLabel: View {
    let windowRouter: WindowRouter

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image("MenuBarIcon")
            .accessibilityLabel(Text(verbatim: "Cloudreve"))
            .onAppear { windowRouter.register(openWindow) }
    }
}
