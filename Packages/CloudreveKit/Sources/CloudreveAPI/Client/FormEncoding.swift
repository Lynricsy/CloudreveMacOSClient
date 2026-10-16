import Foundation

/// 严格的 percent-encode：仅保留 RFC 3986 unreserved 字符（`A-Za-z0-9-._~`），
/// 空格编码为 `%20`，`+` 编码为 `%2B`（Go 解析查询时会把 `+` 当空格）。
public enum FormEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    public static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 编码为 `k=v&k2=v2`。
    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}
