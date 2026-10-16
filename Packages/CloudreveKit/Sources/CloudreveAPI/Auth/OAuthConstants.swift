import Foundation

/// 服务端内置的桌面端 OAuth client（与 Windows 版 cloudreve/desktop 相同）。
public enum OAuthConstants {
    public static let clientID = "393a1839-f52e-498e-9972-e77cc2241eee"
    public static let clientSecret = "8GaQIu3lOSdqYoDHi9cR8IZ4pvuMH8ya"
    public static let scopes = "profile email openid offline_access UserInfo.Write Workflow.Write Files.Write Shares.Write"
    public static let callbackPath = "/callback/desktop"
    public static let minimumServerVersion = "4.12.0"
    /// 网页回跳客户端使用的 URL scheme（`cloudreve://mount?...`）。
    public static let callbackScheme = "cloudreve"
    /// 重新授权时 state 前缀；服务端据此跳过挂载目录选择。
    public static let reauthorizePrefix = "reauthorize:"

    /// 构造授权页 URL。查询参数统一严格编码（空格为 `%20`）。
    public static func authorizeURL(site: URL, codeChallenge: String, state: String) -> URL? {
        let pairs: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("scope", scopes),
            ("redirect_uri", callbackPath),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state)
        ]
        let base = CloudreveClient.normalize(site: site).absoluteString
        return URL(string: base + "/session/authorize?" + FormEncoding.encode(pairs))
    }
}
