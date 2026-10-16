import AppKit
import AuthenticationServices
import CloudreveAPI
import Foundation

/// 浏览器 OAuth 授权（授权码 + PKCE）。
///
/// 回跳 `cloudreve://mount?...` 有两条到达路径：`ASWebAuthenticationSession` 自身拦截，
/// 或系统把 URL 交给 `AppDelegate.application(_:open:)` → `handleExternalCallback(_:)`。
/// 两条路径都按 `state` 查 `pending`，取出即删除，因此 continuation 恰好恢复一次。
@MainActor
final class OAuthFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthFlow()

    private var pending: [String: PendingAuthorization] = [:]
    private var anchor: NSWindow?

    /// 打开授权页并等待回跳。任务被取消时结束会话并抛 `OAuthError.cancelled`。
    func authorize(site: URL, pkce: PKCE, state: String, anchor: NSWindow?) async throws -> OAuthCallback {
        guard let url = OAuthConstants.authorizeURL(site: site, codeChallenge: pkce.challenge, state: state) else {
            throw OAuthError.sessionFailed(String(localized: "无法构造授权地址"))
        }
        self.anchor = anchor
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: OAuthError.cancelled)
                    return
                }
                begin(url: url, state: state, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in self.complete(state: state, with: .failure(.cancelled)) }
        }
    }

    /// 处理系统转交的 URL（App 被 `cloudreve://` scheme 唤起）。非授权回跳或无对应会话时忽略。
    func handleExternalCallback(_ url: URL) {
        guard url.scheme?.lowercased() == OAuthConstants.callbackScheme,
              url.host()?.lowercased() == OAuthCallback.host else {
            Log.shared.info("OAuth", "忽略外部 URL：\(url.absoluteString)")
            return
        }
        // 网页失败回跳可能不带 state；只有一个进行中的授权时交给它。
        let state = OAuthCallback.state(in: url) ?? (pending.count == 1 ? pending.keys.first : nil)
        guard let state, pending[state] != nil else {
            Log.shared.info("OAuth", "收到无对应会话的授权回跳")
            return
        }
        complete(state: state, with: OAuthCallback.parse(url, expectedState: state))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? NSApplication.shared.keyWindow ?? NSWindow()
    }

    private func begin(url: URL, state: String, continuation: CheckedContinuation<OAuthCallback, any Error>) {
        let session = ASWebAuthenticationSession(
            url: url, callback: .customScheme(OAuthConstants.callbackScheme)
        ) { @Sendable callbackURL, error in
            let outcome = Self.outcome(callbackURL: callbackURL, error: error, state: state)
            Task { @MainActor in OAuthFlow.shared.complete(state: state, with: outcome) }
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        pending[state] = PendingAuthorization(continuation: continuation, session: session)
        if !session.start() {
            complete(state: state, with: .failure(.sessionFailed(String(localized: "无法打开授权页面"))))
        }
    }

    /// 把会话完成回调翻译为结果（在任意线程调用，只做纯解析）。
    private nonisolated static func outcome(
        callbackURL: URL?, error: (any Error)?, state: String
    ) -> Result<OAuthCallback, OAuthError> {
        if let callbackURL {
            return OAuthCallback.parse(callbackURL, expectedState: state)
        }
        if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
            return .failure(.cancelled)
        }
        return .failure(.sessionFailed(error?.localizedDescription ?? String(localized: "未知错误")))
    }

    /// 恢复 `state` 对应的 continuation（若仍在等待）并结束会话；重复调用无副作用。
    private func complete(state: String, with outcome: Result<OAuthCallback, OAuthError>) {
        guard let entry = pending.removeValue(forKey: state) else { return }
        if pending.isEmpty { anchor = nil }
        entry.session.cancel()
        entry.continuation.resume(with: outcome)
    }
}
