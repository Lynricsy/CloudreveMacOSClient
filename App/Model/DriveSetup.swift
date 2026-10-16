import CloudreveAPI
import CloudreveSync
import Foundation

/// 新云盘授权完成后收集到的信息，用于生成 `drive` 行与其根目录 `item` 行。
struct DriveSetup: Sendable {
    let driveID: String
    let clientID: UUID
    let site: URL
    let rootURI: CloudreveURI
    let root: FileResponse
    let name: String
    let userID: String
    let user: User
    let siteTitle: String?
    let capacity: Capacity

    func driveRecord(now: Date) -> DriveRecord {
        DriveRecord(
            id: driveID, name: name, siteURL: site, remoteRootURI: rootURI, rootFileID: root.id,
            userID: userID, userEmail: user.email, siteTitle: siteTitle, clientID: clientID, status: .active,
            ignorePatterns: [], capacityTotal: capacity.total, capacityUsed: capacity.used,
            capacityUpdatedAt: now, createdAt: now
        )
    }

    /// 根目录行：id 为远端根目录 id，`parentID` 为 nil，名称取云盘名。
    func rootItem() -> ItemRecord {
        ItemRecord(
            driveID: driveID, id: root.id, parentID: nil, name: name, isFolder: true, size: 0,
            entityID: root.primaryEntity ?? "", uri: rootURI, createdAt: root.createdAt, updatedAt: root.updatedAt
        )
    }
}
