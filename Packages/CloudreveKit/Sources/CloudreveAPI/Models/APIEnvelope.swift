import Foundation

/// Cloudreve 统一响应包装：`code == 0` 成功，否则为业务错误（HTTP 仍为 200）。
public struct APIEnvelope<T: Decodable>: Decodable {
    public let code: Int
    public let msg: String?
    public let data: T?
    public let error: String?
    public let correlationID: String?

    enum CodingKeys: String, CodingKey {
        case code, msg, data, error
        case correlationID = "correlation_id"
    }
}

extension APIEnvelope: Sendable where T: Sendable {}

/// 不关心 `data` 内容的响应；接受任意 JSON 值（含 null）。
public struct EmptyData: Decodable, Sendable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}
