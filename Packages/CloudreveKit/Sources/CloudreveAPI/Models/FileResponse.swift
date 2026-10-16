import Foundation

/// 服务端文件/目录对象。
public struct FileResponse: Codable, Sendable, Equatable {
    public var type: Int
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var size: Int64
    public var metadata: [String: String]?
    public var path: String?
    public var primaryEntity: String?

    public var isFolder: Bool { type == 1 }

    public init(
        type: Int, id: String, name: String, createdAt: Date, updatedAt: Date, size: Int64,
        metadata: [String: String]? = nil, path: String? = nil, primaryEntity: String? = nil
    ) {
        self.type = type
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.size = size
        self.metadata = metadata
        self.path = path
        self.primaryEntity = primaryEntity
    }

    enum CodingKeys: String, CodingKey {
        case type, id, name, size, metadata, path
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case primaryEntity = "primary_entity"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(Int.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        metadata = try? container.decodeIfPresent([String: String].self, forKey: .metadata)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        primaryEntity = try container.decodeIfPresent(String.self, forKey: .primaryEntity)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(CloudreveDate.format(createdAt), forKey: .createdAt)
        try container.encode(CloudreveDate.format(updatedAt), forKey: .updatedAt)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(primaryEntity, forKey: .primaryEntity)
    }
}
