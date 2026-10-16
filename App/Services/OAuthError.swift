import Foundation

/// 浏览器授权流程的错误。
enum OAuthError: LocalizedError, Sendable, Equatable {
    /// 用户关闭了授权窗口或取消了流程。
    case cancelled
    /// 网页回跳携带 `error` 参数（用户拒绝或服务端报错）。
    case denied(String)
    /// 回跳的 `state` 与发起时不一致。
    case stateMismatch
    /// 回跳 URL 不是 `cloudreve://mount` 或缺少 `code`。
    case invalidCallback
    /// 授权会话无法启动或异常结束。
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "已取消授权")
        case .denied(let reason):
            String(localized: "授权被拒绝：\(reason)")
        case .stateMismatch:
            String(localized: "授权回调校验失败，请重试")
        case .invalidCallback:
            String(localized: "授权回调无效，请重试")
        case .sessionFailed(let reason):
            String(localized: "无法完成授权：\(reason)")
        }
    }
}
