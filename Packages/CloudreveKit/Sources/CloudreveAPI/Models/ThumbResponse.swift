import Foundation

/// `GET /file/thumb` 响应：缩略图 URL，而非字节。
public struct ThumbResponse: Decodable, Sendable {
    public var url: String
    public var expires: Date?
    public var obfuscated: Bool?

    enum CodingKeys: String, CodingKey {
        case url, expires, obfuscated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        expires = try? container.decodeIfPresent(Date.self, forKey: .expires)
        obfuscated = try container.decodeIfPresent(Bool.self, forKey: .obfuscated)
    }
}
