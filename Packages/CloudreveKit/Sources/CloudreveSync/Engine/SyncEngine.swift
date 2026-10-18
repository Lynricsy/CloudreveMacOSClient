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
    let remoteEvents: RemoteEventQueue
    let listings = ListingTracker()
    /// 远端变更队列的单消费者门闩：多个枚举请求可能并发 drain，同一批不得被两边同时应用。
    let remoteDrain = SerialGate()

    /// 列目录每页数量。
    static let pageSize = 1000
    /// 变更枚举每批上限。
    static let changeBatchLimit = 1000
    /// 远端变更队列每批上限。
    static let remoteEventBatchLimit = 500

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
        remoteEvents = RemoteEventQueue(db: db, now: now)
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
            guard let records = try self.changeLog.retainedChanges(
                driveID: self.driveID, afterSeq: anchor, limit: Self.changeBatchLimit
            ) else { throw SyncError.syncAnchorExpired }
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

    /// 把服务端对象写入镜像（同一事务记变更日志），返回引擎条目。
    @discardableResult
    func store(_ file: FileResponse, parentID: String, uri: CloudreveURI) throws -> SyncItem {
        let record = ItemRecord(file: file, driveID: driveID, parentID: parentID, uri: uri)
        try items.upsert([record])
        return SyncItem(record: record)
    }

    /// 删除本地镜像中的条目（目录连同全部后代），同一事务记 `delete`。
    func removeLocally(_ records: [ItemRecord]) throws {
        var ids: [String] = []
        for record in records {
            if record.isFolder {
                ids += try items.descendants(driveID: driveID, uriPrefix: record.uri).map(\.id)
            }
            ids.append(record.id)
        }
        try items.delete(driveID: driveID, ids: ids)
    }

    /// 列目录的一页。首页开始一个枚举会话，会话 id 编进返回的分页令牌；末页按会话累计的 id 计算删除差集。
    private func listFolderPage(id: String, pageToken: String?) async throws -> EnumerationPage {
        let uri = try await resolveFolderURI(id: id)
        let token = pageToken.map(ListingPageToken.init(parsing:))
        let startSeq = token == nil ? try changeLog.latestSeq(driveID: driveID) : 0
        let (records, next) = try await listPage(folderID: id, uri: uri, serverToken: token?.server)
        let ids = records.map(\.id)
        var session = token?.session
        var finished: ListingSession?
        switch (token, next) {
        case (nil, nil):
            finished = ListingSession(folderID: id, startSeq: startSeq, seen: Set(ids))
        case (nil, _):
            session = await listings.start(folderID: id, startSeq: startSeq, ids: ids)
        case (_, nil):
            if let session { finished = await listings.finish(session: session, folderID: id, ids: ids) }
        default:
            if let session { await listings.record(session: session, folderID: id, ids: ids) }
        }
        if next == nil {
            if let finished {
                try items.removeUnseenChildren(driveID: driveID, parentID: id, seen: finished.seen, unchangedAfter: finished.startSeq)
            }
            try items.markEnumerated(driveID: driveID, id: id, at: now())
        }
        return EnumerationPage(
            items: records.map(SyncItem.init(record:)),
            nextToken: next.map { ListingPageToken(session: session, server: $0).encoded }
        )
    }

    /// 列目录的一页并写入镜像，返回本页条目与服务端下一页令牌（末页为 nil）。`parking` 见 `ItemStore.upsert`。
    func listPage(
        folderID: String, uri: CloudreveURI, serverToken: String?, parking: CloudreveURI? = nil
    ) async throws -> ([ItemRecord], String?) {
        let response = try await client.listFiles(uri: uri, pageSize: Self.pageSize, nextPageToken: serverToken)
        let records = response.files.map {
            ItemRecord(file: $0, driveID: driveID, parentID: folderID, uri: uri.appending($0.name))
        }
        try items.upsert(records, parkingOccupantsUnder: parking)
        return (records, response.pagination?.nextToken.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// 目录 URI；本地无记录时按 id 向服务端查询并补写镜像。查询结果已不在挂载根之内时报 `.noSuchItem`，
    /// 不得列出或存储根外子项。
    func resolveFolderURI(id: String) async throws -> CloudreveURI {
        if try id == rootID || items.get(driveID: driveID, id: id) != nil {
            return try folderURI(id: id)
        }
        guard let remote = try await remoteItem(id: id), remote.file.isFolder else { throw SyncError.noSuchItem }
        let uri = remote.uri
        if let parentURI = uri.parent, let parentID = try parentID(forURI: parentURI) {
            try store(remote.file, parentID: parentID, uri: uri)
        }
        return uri
    }

    /// 按 id 查询服务端当前条目与路径（镜像中的路径可能已过期）；已不存在或已不在挂载根之内（含根本身）时返回 nil。
    func remoteItem(id: String) async throws -> (file: FileResponse, uri: CloudreveURI)? {
        let info: FileResponse
        do {
            info = try await client.fileInfo(id: id)
        } catch where Self.isNotFound(error) {
            return nil
        }
        guard let path = info.path, let uri = CloudreveURI(string: path) else {
            throw CloudreveAPIError.decoding("/file/info 缺少有效 path")
        }
        guard try isStrictlyInsideRoot(uri) else { return nil }
        return (info, uri)
    }

    /// 服务端报告条目不存在（404 / 40044）。
    static func isNotFound(_ error: any Error) -> Bool {
        SyncErrorMapper.map(error) as? SyncError == .noSuchItem
    }

    /// 是否在挂载根之下（不含根本身）；按编码文本逐字节比较，不受规范等价影响。
    func isStrictlyInsideRoot(_ uri: CloudreveURI) throws -> Bool {
        let root = try drive().remoteRootURI.description
        let text = uri.description
        return text != root && ItemStore.isWithin(text, root)
    }

    /// 已知目录 URI → id（挂载根 → rootID）；未知返回 nil。
    func parentID(forURI uri: CloudreveURI) throws -> String? {
        if uri.description == (try drive().remoteRootURI).description { return rootID }
        guard let record = try items.getByURI(driveID: driveID, uri: uri), record.isFolder else { return nil }
        return record.id
    }

    /// 目录 URI → id；镜像缺少该目录（及其祖先）时逐级向服务端补查并写入镜像（不标记为已枚举）。
    /// 不在挂载根之内、服务端已不存在或不是目录时返回 nil。用于条目被远端移进镜像尚未见过的目录时定位其父目录，
    /// 不能因为本地缺少父目录就把仍存在的条目当成已删除。
    func resolveFolderID(forURI uri: CloudreveURI) async throws -> String? {
        if let id = try parentID(forURI: uri) { return id }
        guard try isStrictlyInsideRoot(uri), let parentURI = uri.parent,
              let parentID = try await resolveFolderID(forURI: parentURI) else { return nil }
        let info: FileResponse
        do {
            info = try await client.fileInfo(uri: uri)
        } catch where Self.isNotFound(error) {
            return nil
        }
        guard info.isFolder else { return nil }
        try store(info, parentID: parentID, uri: uri)
        return info.id
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
