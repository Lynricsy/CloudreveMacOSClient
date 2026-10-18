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
    /// 仅 `/file/info?extended=true` 返回。
    public var extendedInfo: FileExtendedInfo?

    public var isFolder: Bool { type == 1 }

    public init(
        type: Int, id: String, name: String, createdAt: Date, updatedAt: Date, size: Int64,
        metadata: [String: String]? = nil, path: String? = nil, primaryEntity: String? = nil,
        extendedInfo: FileExtendedInfo? = nil
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
        self.extendedInfo = extendedInfo
    }

    enum CodingKeys: String, CodingKey {
        case type, id, name, size, metadata, path
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case primaryEntity = "primary_entity"
        case extendedInfo = "extended_info"
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
        extendedInfo = try container.decodeIfPresent(FileExtendedInfo.self, forKey: .extendedInfo)
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
        try container.encodeIfPresent(extendedInfo, forKey: .extendedInfo)
    }
}

/// 文件扩展信息；只解析客户端用到的字段。
public struct FileExtendedInfo: Codable, Sendable, Equatable {
    /// 文件的全部实体（当前版本、历史版本及缩略图等）。
    public var entities: [FileEntity]

    public init(entities: [FileEntity]) {
        self.entities = entities
    }

    enum CodingKeys: String, CodingKey {
        case entities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 服务端以 omitempty 输出，没有实体时省略该字段
        entities = try container.decodeIfPresent([FileEntity].self, forKey: .entities) ?? []
    }
}

/// 文件的一个实体。
public struct FileEntity: Codable, Sendable, Equatable {
    public var id: String
    public var size: Int64
    /// 实体明文内容的 SHA-256（小写十六进制）。只有 OpenCloudreve 返回，且仅限服务端已算出的本机/从机策略实体；
    /// 官方 Cloudreve、其他存储策略或尚未算完时缺失。
    public var sha256: String?

    public init(id: String, size: Int64, sha256: String? = nil) {
        self.id = id
        self.size = size
        self.sha256 = sha256
    }
}
