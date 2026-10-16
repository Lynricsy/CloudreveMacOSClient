import Foundation

/// 协议层错误。
public enum CloudreveAPIError: Error, Sendable, Equatable {
    /// 业务错误：HTTP 200 但 `code != 0`。
    case server(code: Int, message: String, correlationID: String?)
    /// 非 2xx 的 HTTP 状态。
    case http(status: Int, body: String)
    /// 网络/连接错误。
    case transport(String)
    /// 响应解码失败。
    case decoding(String)
    /// OAuth 换 token 响应缺少 refresh_token。
    case missingRefreshToken
    /// 凭证失效且无法刷新，需要重新登录。
    case credentialInvalid
    /// 存储策略要求客户端加密，不支持。
    case unsupportedEncryption

    /// 表示凭证失效的业务码。
    public static let credentialCodes: Set<Int> = [401, 40020, 40089]

    /// 业务错误码（非 `.server` 为 nil）。
    public var serverCode: Int? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }
}

extension CloudreveAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .server(code, message, _): return "服务器错误 \(code)：\(message)"
        case let .http(status, body): return "HTTP \(status)：\(body.prefix(200))"
        case .transport(let message): return "网络错误：\(message)"
        case .decoding(let message): return "响应解析失败：\(message)"
        case .missingRefreshToken: return "授权响应缺少刷新令牌"
        case .credentialInvalid: return "登录已失效，请重新登录"
        case .unsupportedEncryption: return "该存储策略要求客户端加密，暂不支持"
        }
    }
}
