import AppKit
import SwiftUI

/// 让非视图代码（`AppDelegate` 的通知回调）打开 SwiftUI 窗口。
///
/// `OpenWindowAction` 只能从视图环境取得：菜单栏图标标签视图在 App 生命周期内常驻，
/// 它（以及弹窗）出现时调用 `register(_:)` 交出该动作。注册之前到达的请求排队，
/// 注册后立即补发，因此「点击通知冷启动 App」也不会丢失请求。
@MainActor
final class WindowRouter {
    private var openWindow: OpenWindowAction?
    private var queued: [AddDriveRequest] = []

    func register(_ action: OpenWindowAction) {
        openWindow = action
        flush()
    }

    /// 打开（或前置）添加云盘/重新登录窗口。
    func show(_ request: AddDriveRequest) {
        queued.append(request)
        flush()
    }

    /// 视图内直接使用自身环境中的 `openWindow` 打开窗口，并激活 App（菜单栏 App 默认不在前台）。
    static func present(_ request: AddDriveRequest, using openWindow: OpenWindowAction) {
        openWindow(id: AddDriveRequest.windowID, value: request)
        NSApplication.shared.activate()
    }

    private func flush() {
        guard let openWindow, !queued.isEmpty else { return }
        let requests = queued
        queued.removeAll()
        for request in requests {
            Self.present(request, using: openWindow)
        }
    }
}
