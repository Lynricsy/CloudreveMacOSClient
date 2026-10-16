import Foundation

/// `POST /file/url` 响应。
public struct DownloadURLsResponse: Decodable, Sendable {
    public struct URLEntry: Decodable, Sendable {
        public var url: String
    }

    public var urls: [URLEntry]
    public var expires: Date?

    enum CodingKeys: String, CodingKey {
        case urls, expires
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urls = try container.decodeIfPresent([URLEntry].self, forKey: .urls) ?? []
        expires = try? container.decodeIfPresent(Date.self, forKey: .expires)
    }
}
