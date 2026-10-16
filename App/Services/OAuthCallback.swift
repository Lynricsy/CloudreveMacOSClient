import Foundation

/// 网页授权完成后回跳 `cloudreve://mount?code=&state=&user_id=[&path=][&name=]` 的解析结果。
struct OAuthCallback: Equatable, Sendable {
    let code: String
    let state: String
    /// 服务端用户 id；可能为空串（此时以 `/user/me` 为准）。
    let userID: String
    /// 用户在网页挂载设置中填写的云盘名称。
    let name: String?
    /// 用户选择的远端挂载目录（通常为 `cloudreve://my/...`）。
    let path: String?

    static let host = "mount"

    /// 解析回跳 URL：`error` 参数 → `.denied`；state 不符 → `.stateMismatch`；缺 `code` → `.invalidCallback`。
    static func parse(_ url: URL, expectedState: String) -> Result<OAuthCallback, OAuthError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "cloudreve", components.host?.lowercased() == host else {
            return .failure(.invalidCallback)
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = value("error") {
            return .failure(.denied(error))
        }
        guard value("state") == expectedState else { return .failure(.stateMismatch) }
        guard let code = value("code") else { return .failure(.invalidCallback) }
        return .success(OAuthCallback(
            code: code, state: expectedState, userID: value("user_id") ?? "", name: value("name"), path: value("path")
        ))
    }

    /// 回跳 URL 中的 `state`（用于把外部打开的 URL 路由到对应的进行中授权）。
    static func state(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
    }
}
