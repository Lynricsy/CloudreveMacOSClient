import CloudreveAPI
import Foundation

extension SyncItem {
    /// 镜像行 → 引擎条目。
    public init(record: ItemRecord) {
        self.init(
            id: record.id, parentID: record.parentID, name: record.name, isFolder: record.isFolder, size: record.size,
            entityID: record.entityID, createdAt: record.createdAt, updatedAt: record.updatedAt, uri: record.uri
        )
    }
}

extension ItemRecord {
    /// 服务端对象 → 镜像行。`uri` 由调用方按父目录拼接（比 `path` 字段更可靠）。
    init(file: FileResponse, driveID: String, parentID: String, uri: CloudreveURI) {
        self.init(
            driveID: driveID, id: file.id, parentID: parentID, name: file.name, isFolder: file.isFolder,
            size: file.isFolder ? 0 : file.size, entityID: file.primaryEntity ?? "", uri: uri,
            createdAt: file.createdAt, updatedAt: file.updatedAt
        )
    }
}
