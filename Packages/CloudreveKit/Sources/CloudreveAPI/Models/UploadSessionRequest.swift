import Foundation

/// 创建上传会话的请求体。
/// 注意：目标不存在时**不能**携带 `entity_type`（空串也会被服务端视为非 version），
/// 所以 `entityType == nil` 时不编码该键。
public struct UploadSessionRequest: Encodable, Sendable, Equatable {
    public var uri: String
    public var size: Int64
    /// 毫秒时间戳。
    public var lastModified: Int64
    public var mimeType: String
    public var policyID: String
    public var entityType: String?
    public var previous: String?

    public init(
        uri: String, size: Int64, lastModified: Int64, mimeType: String,
        policyID: String = "", entityType: String? = nil, previous: String? = nil
    ) {
        self.uri = uri
        self.size = size
        self.lastModified = lastModified
        self.mimeType = mimeType
        self.policyID = policyID
        self.entityType = entityType
        self.previous = previous
    }

    enum CodingKeys: String, CodingKey {
        case uri, size, previous
        case lastModified = "last_modified"
        case mimeType = "mime_type"
        case policyID = "policy_id"
        case entityType = "entity_type"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encode(size, forKey: .size)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(policyID, forKey: .policyID)
        try container.encodeIfPresent(entityType, forKey: .entityType)
        try container.encodeIfPresent(previous, forKey: .previous)
    }
}
