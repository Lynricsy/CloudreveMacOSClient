import CloudreveAPI
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// 引擎对外暴露的条目（扩展层映射为 NSFileProviderItem）。
public struct SyncItem: Sendable, Equatable {
    public var id: String
    /// nil 表示根容器本身。
    public var parentID: String?
    public var name: String
    public var isFolder: Bool
    public var size: Int64
    /// 当前主版本 entity id（内容版本）。
    public var entityID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var uri: CloudreveURI

    public init(
        id: String, parentID: String?, name: String, isFolder: Bool, size: Int64,
        entityID: String, createdAt: Date, updatedAt: Date, uri: CloudreveURI
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.entityID = entityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.uri = uri
    }

    /// 内容版本 = entity id；元数据版本覆盖名称、父目录、修改时间与大小。
    /// SDK 限制每个分量 ≤128 字节，长文件名直接拼接会超限，因此元数据分量取拼接串 SHA-256 的十六进制（64 字节）。
    public var version: ItemVersion {
        let millis = Int64(updatedAt.timeIntervalSince1970 * 1000)
        let separator = "\u{1F}"
        let joined = [name, parentID ?? "", String(millis), String(size)].joined(separator: separator)
        let metadata = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return ItemVersion(content: entityID, metadata: metadata)
    }
}

/// 条目版本（两个分量分别对应 NSFileProviderItemVersion 的 content/metadata）。
public struct ItemVersion: Sendable, Equatable {
    public var content: String
    public var metadata: String

    public init(content: String, metadata: String) {
        self.content = content
        self.metadata = metadata
    }
}
