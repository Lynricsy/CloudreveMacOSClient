import CloudreveAPI
import Foundation
import GRDB

/// 单个云盘的同步引擎：所有同步决策与本地镜像持久化都在这里，扩展层只做类型桥接。
public final class SyncEngine: Sendable {
    public typealias ProgressHandler = @Sendable (_ done: Int64, _ total: Int64) -> Void

    public let driveID: String
    public let rootID: String
    let client: CloudreveClient
    let uploader: Uploader
    let now: @Sendable () -> Date
    let drives: DriveStore
    let items: ItemStore
    let changeLog: ChangeLog
    let transfers: TransferStore
    let listings = ListingTracker()

    /// 列目录每页数量。
    static let pageSize = 1000
    /// 变更枚举每批上限。
    static let changeBatchLimit = 1000

    public init(
        driveID: String, db: any DatabaseWriter, client: CloudreveClient, uploader: Uploader,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.driveID = driveID
        self.client = client
        self.uploader = uploader
        self.now = now
        drives = DriveStore(db: db, now: now)
        items = ItemStore(db: db, now: now)
        changeLog = ChangeLog(db: db, now: now)
        transfers = TransferStore(db: db, now: now)
        guard let drive = try drives.get(id: driveID) else { throw SyncError.noSuchItem }
        rootID = drive.rootFileID
    }

    // MARK: - 查询

    public func item(id: String) async throws -> SyncItem {
        try await run { try self.localItem(id: id) }
    }

    /// 列出目录的一页并更新本地镜像；末页时删除本轮未出现的子项。
    public func enumerateFolder(id: String, pageToken: String?) async throws -> EnumerationPage {
        try await run { try await self.listFolderPage(id: id, pageToken: pageToken) }
    }

    /// working set（全部已知非根条目），按 rowid 分页。
    public func workingSetItems(afterRowID: Int64, limit: Int = 500) async throws -> ([SyncItem], Int64?) {
        try await run {
            let (records, next) = try self.items.page(driveID: self.driveID, afterRowID: afterRowID, limit: limit)
            return (records.map(SyncItem.init(record:)), next)
        }
    }

    public func currentAnchor() async throws -> Int64 {
        try await run { try self.changeLog.latestSeq(driveID: self.driveID) }
    }

    /// 自 `anchor` 以来的变化；anchor 早于已裁剪的日志或晚于最新序号时抛 `.syncAnchorExpired`。
    public func changes(since anchor: Int64) async throws -> ChangeBatch {
        try await run {
            let latest = try self.changeLog.latestSeq(driveID: self.driveID)
            if let oldest = try self.changeLog.oldestSeq(driveID: self.driveID), anchor < oldest - 1 {
                throw SyncError.syncAnchorExpired
            }
            if anchor > latest { throw SyncError.syncAnchorExpired }
            let records = try self.changeLog.changes(driveID: self.driveID, afterSeq: anchor, limit: Self.changeBatchLimit)
            return try self.mergeChanges(records, anchor: anchor)
        }
    }

    // MARK: - 内部

    /// 包装公开方法：错误统一映射为 SyncError；凭证失效时标记云盘状态。
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            let mapped = SyncErrorMapper.map(error)
            if case SyncError.notAuthenticated? = mapped as? SyncError {
                try? drives.updateStatus(id: driveID, .credentialExpired)
            }
            if !(mapped is CancellationError) {
                Log.shared.error("engine", "云盘 \(driveID) 操作失败：\(error)")
            }
            throw mapped
        }
    }

    func drive() throws -> DriveRecord {
        guard let drive = try drives.get(id: driveID) else { throw SyncError.noSuchItem }
        return drive
    }

    /// 根容器以云盘名称展示。
    func rootItem() throws -> SyncItem {
        let drive = try drive()
        let record = try items.get(driveID: driveID, id: rootID)
        return SyncItem(
            id: rootID, parentID: nil, name: drive.name, isFolder: true, size: 0, entityID: "",
            createdAt: record?.createdAt ?? drive.createdAt, updatedAt: record?.updatedAt ?? drive.createdAt,
            uri: drive.remoteRootURI
        )
    }

    func localItem(id: String) throws -> SyncItem {
        if id == rootID { return try rootItem() }
        guard let record = try items.get(driveID: driveID, id: id) else { throw SyncError.noSuchItem }
        return SyncItem(record: record)
    }

    func localRecord(id: String) throws -> ItemRecord {
        guard let record = try items.get(driveID: driveID, id: id) else { throw SyncError.noSuchItem }
        return record
    }

    /// 目录 id → 远端 URI（根为挂载根 URI）。
    func folderURI(id: String) throws -> CloudreveURI {
        if id == rootID { return try drive().remoteRootURI }
        let record = try localRecord(id: id)
        guard record.isFolder else { throw SyncError.cannotSynchronize("目标不是目录") }
        return record.uri
    }

    /// 把服务端对象写入镜像并记变更日志，返回引擎条目。
    @discardableResult
    func store(_ file: FileResponse, parentID: String, uri: CloudreveURI) throws -> SyncItem {
        let record = ItemRecord(file: file, driveID: driveID, parentID: parentID, uri: uri)
        let changed = try items.upsert([record])
        try changeLog.appendMany(driveID: driveID, itemIDs: changed, kind: .update)
        return SyncItem(record: record)
    }

    /// 删除本地镜像中的条目（目录连同全部后代），并记 `delete`。
    func removeLocally(_ records: [ItemRecord]) throws {
        var ids: [String] = []
        for record in records {
            if record.isFolder {
                ids += try items.descendants(driveID: driveID, uriPrefix: record.uri).map(\.id)
            }
            ids.append(record.id)
        }
        guard !ids.isEmpty else { return }
        try items.delete(driveID: driveID, ids: ids)
        try changeLog.appendMany(driveID: driveID, itemIDs: ids, kind: .delete)
    }

    private func listFolderPage(id: String, pageToken: String?) async throws -> EnumerationPage {
        let uri = try await resolveFolderURI(id: id)
        let isFirstPage = pageToken == nil
        let response = try await client.listFiles(uri: uri, pageSize: Self.pageSize, nextPageToken: pageToken)
        let records = response.files.map {
            ItemRecord(file: $0, driveID: driveID, parentID: id, uri: uri.appending($0.name))
        }
        let changed = try items.upsert(records)
        try changeLog.appendMany(driveID: driveID, itemIDs: changed, kind: .update)
        await listings.record(folderID: id, ids: records.map(\.id), isFirstPage: isFirstPage)
        let next = response.pagination?.nextToken.flatMap { $0.isEmpty ? nil : $0 }
        if next == nil {
            if let seen = await listings.finish(folderID: id) {
                let stale = try items.children(driveID: driveID, parentID: id).filter { !seen.contains($0.id) }
                try removeLocally(stale)
            }
            try items.markEnumerated(driveID: driveID, id: id, at: now())
        }
        return EnumerationPage(items: records.map(SyncItem.init(record:)), nextToken: next)
    }

    /// 目录 URI；本地无记录时向服务端查询并补写镜像。
    private func resolveFolderURI(id: String) async throws -> CloudreveURI {
        if try id == rootID || items.get(driveID: driveID, id: id) != nil {
            return try folderURI(id: id)
        }
        let info = try await client.fileInfo(id: id)
        guard info.isFolder, let path = info.path, let uri = CloudreveURI(string: path) else { throw SyncError.noSuchItem }
        if let parentURI = uri.parent, let parentID = try parentID(forURI: parentURI) {
            try store(info, parentID: parentID, uri: uri)
        }
        return uri
    }

    /// 已知目录 URI → id（挂载根 → rootID）；未知返回 nil。
    func parentID(forURI uri: CloudreveURI) throws -> String? {
        if uri == (try drive().remoteRootURI) { return rootID }
        guard let record = try items.getByURI(driveID: driveID, uri: uri), record.isFolder else { return nil }
        return record.id
    }

    private func mergeChanges(_ records: [ChangeLogRecord], anchor: Int64) throws -> ChangeBatch {
        var order: [String] = []
        var lastKind: [String: ChangeKind] = [:]
        for record in records {
            if lastKind[record.itemID] == nil { order.append(record.itemID) }
            lastKind[record.itemID] = record.kind
        }
        var updated: [SyncItem] = []
        var deleted: [String] = []
        for id in order {
            if lastKind[id] == .update, let item = try? localItem(id: id) {
                updated.append(item)
            } else {
                deleted.append(id)
            }
        }
        return ChangeBatch(
            updated: updated, deleted: deleted, anchor: records.last?.seq ?? anchor,
            moreComing: records.count >= Self.changeBatchLimit
        )
    }
}
