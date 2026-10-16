import CryptoKit
import Foundation
import Security

/// OAuth2 PKCE（RFC 7636，S256）：随机 verifier 与其 SHA-256 challenge。
struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    /// 32 字节系统随机数 → base64url（无填充）作为 verifier。
    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OAuthError.sessionFailed(String(localized: "无法生成安全随机数"))
        }
        let verifier = Self.base64URL(Data(bytes))
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url 编码（`+`→`-`，`/`→`_`，去掉 `=` 填充）。
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
