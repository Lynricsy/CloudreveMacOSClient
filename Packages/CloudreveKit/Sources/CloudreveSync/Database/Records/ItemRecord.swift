import CloudreveAPI
import Foundation
import GRDB

/// `item` 表：远端文件/目录在本地的镜像。根目录行的 `parentID` 为 nil。
public struct ItemRecord: SyncRecord, Equatable {
    public static let databaseTableName = "item"

    public var driveID: String
    public var id: String
    public var parentID: String?
    public var name: String
    public var isFolder: Bool
    public var size: Int64
    /// 服务端 `primary_entity`，作为内容版本。
    public var entityID: String
    public var uri: CloudreveURI
    public var createdAt: Date
    public var updatedAt: Date
    /// 目录最近一次完整列目录的时间。
    public var enumeratedAt: Date?

    public init(
        driveID: String, id: String, parentID: String?, name: String, isFolder: Bool, size: Int64 = 0,
        entityID: String = "", uri: CloudreveURI, createdAt: Date, updatedAt: Date, enumeratedAt: Date? = nil
    ) {
        self.driveID = driveID
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.entityID = entityID
        self.uri = uri
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.enumeratedAt = enumeratedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, size, uri
        case driveID = "drive_id"
        case parentID = "parent_id"
        case isFolder = "is_folder"
        case entityID = "entity_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case enumeratedAt = "enumerated_at"
    }

    // `uri` 以文本存储，手写编解码以避免 GRDB 对非基础类型的 JSON 编码。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driveID = try container.decode(String.self, forKey: .driveID)
        id = try container.decode(String.self, forKey: .id)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        name = try container.decode(String.self, forKey: .name)
        isFolder = try container.decode(Bool.self, forKey: .isFolder)
        size = try container.decode(Int64.self, forKey: .size)
        entityID = try container.decode(String.self, forKey: .entityID)
        let text = try container.decode(String.self, forKey: .uri)
        guard let parsed = CloudreveURI(string: text) else {
            throw DecodingError.dataCorruptedError(forKey: .uri, in: container, debugDescription: "无效 URI：\(text)")
        }
        uri = parsed
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        enumeratedAt = try container.decodeIfPresent(Date.self, forKey: .enumeratedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(driveID, forKey: .driveID)
        try container.encode(id, forKey: .id)
        try container.encode(parentID, forKey: .parentID)
        try container.encode(name, forKey: .name)
        try container.encode(isFolder, forKey: .isFolder)
        try container.encode(size, forKey: .size)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(uri.description, forKey: .uri)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(enumeratedAt, forKey: .enumeratedAt)
    }
}

extension ItemRecord {
    /// 是否在同步可见字段上与 `other` 不同（name/parent_id/size/entity_id/updated_at/is_folder）。
    /// 时间按毫秒比较，规避 Double 往返误差；名称与 uri 按实际存储的字节比较（Swift `String ==` 按规范等价，
    /// 会漏掉仅 Unicode 规范化不同的改名）。
    func differsInTrackedFields(from other: ItemRecord) -> Bool {
        !name.unicodeScalars.elementsEqual(other.name.unicodeScalars) || parentID != other.parentID || size != other.size
            || entityID != other.entityID || isFolder != other.isFolder || Self.millis(updatedAt) != Self.millis(other.updatedAt)
    }

    /// 是否需要写回数据库（含 uri、created_at 等非追踪列）。
    func differsInStoredColumns(from other: ItemRecord) -> Bool {
        differsInTrackedFields(from: other) || uri.description != other.uri.description
            || Self.millis(createdAt) != Self.millis(other.createdAt)
            || enumeratedAt.map(Self.millis) != other.enumeratedAt.map(Self.millis)
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
