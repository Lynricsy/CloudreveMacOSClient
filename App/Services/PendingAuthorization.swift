import AuthenticationServices
import Foundation

/// 一次进行中的浏览器授权：等待回跳的 continuation 与持有的会话（会话必须被强引用直到结束）。
@MainActor
struct PendingAuthorization {
    let continuation: CheckedContinuation<OAuthCallback, any Error>
    let session: ASWebAuthenticationSession
}
