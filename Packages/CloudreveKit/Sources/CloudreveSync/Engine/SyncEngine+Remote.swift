import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 应用 SSE 推送的远端事件，返回是否产生了变更日志。
    public func applyRemoteEvents(_ events: [FileEvent]) async throws -> Bool {
        try await run {
            let before = try self.changeLog.latestSeq(driveID: self.driveID)
            try await self.applyEvents(events)
            return try self.changeLog.latestSeq(driveID: self.driveID) != before
        }
    }

    /// 重新完整列出所有曾枚举过的目录（兜底丢失的推送），返回是否产生了变更日志。
    public func reconcile() async throws -> Bool {
        try await run {
            let before = try self.changeLog.latestSeq(driveID: self.driveID)
            try await self.reconcileEnumeratedFolders()
            return try self.changeLog.latestSeq(driveID: self.driveID) != before
        }
    }

    /// 应用 App 落库的远端变更队列：逐批应用，成功后才删除该批（失败时保留，下次重试）。
    /// 含全量兜底请求的批次先应用同批精确事件再 reconcile：reconcile 只重列已枚举目录，
    /// 未枚举目录中已知条目的变化只能靠事件。并发调用经 `remoteDrain` 串行执行。
    /// 返回是否产生了变更日志。
    public func applyQueuedRemoteChanges() async throws -> Bool {
        try await remoteDrain.run { try await self.drainRemoteEvents() }
    }

    private func drainRemoteEvents() async throws -> Bool {
        try await run {
            let before = try self.changeLog.latestSeq(driveID: self.driveID)
            while let batch = try self.remoteEvents.next(driveID: self.driveID, limit: Self.remoteEventBatchLimit) {
                try await self.applyEvents(batch.events)
                if batch.needsReconcile {
                    try await self.reconcileEnumeratedFolders()
                }
                try self.remoteEvents.remove(driveID: self.driveID, throughSeq: batch.lastSeq)
            }
            return try self.changeLog.latestSeq(driveID: self.driveID) != before
        }
    }

    /// 裁剪变更日志与传输记录。
    public func maintenance() async throws {
        try await run {
            try self.changeLog.prune(driveID: self.driveID)
            try self.transfers.prune()
        }
    }

    // MARK: - 内部

    private func applyEvents(_ events: [FileEvent]) async throws {
        for event in events where event.fileID != rootID {
            switch event.type {
            case .create, .modify, .rename:
                try await applyUpsertEvent(event)
            case .delete:
                try applyDeleteEvent(event)
            }
        }
    }

    /// 一个目录完整列出后的结果，删除差集留待整轮扫描结束后提交。
    private struct FolderListing {
        let folderID: String
        let startSeq: Int64
        let seen: Set<String>
    }

    /// 整轮扫描所有已枚举目录：先只做插入与按 id 更新（目录换位置时后代随之迁移、保留 enumeratedAt），
    /// 全部列完后再提交各目录的删除差集。边列边删会把移到后面目录里的子树先删掉再以未枚举状态补回。
    /// 扫描中被新条目占用路径的旧条目同理不立即删除，而是暂存（见 `ItemStore.upsert`），整轮结束仍未出现才删除；
    /// 扫描失败时暂存行同样删除，不得以占位路径残留在镜像中。
    private func reconcileEnumeratedFolders() async throws {
        let parking = CloudreveURI(segments: ["\u{1}reconcile-\(UUID().uuidString)"])
        do {
            try await scanEnumeratedFolders(parking: parking)
        } catch {
            try? items.purgeParked(driveID: driveID, parking: parking)
            throw error
        }
        try items.purgeParked(driveID: driveID, parking: parking)
        try drives.updateLastReconcile(id: driveID)
    }

    private func scanEnumeratedFolders(parking: CloudreveURI) async throws {
        var listings: [FolderListing] = []
        var missing: [(id: String, uri: String)] = []
        for folder in try items.enumeratedFolders(driveID: driveID) {
            if let listing = try await listWholeFolder(id: folder.id, parking: parking) {
                listings.append(listing)
            } else {
                missing.append((folder.id, folder.uri.description))
            }
        }
        // 按旧路径找不到（或已被暂存）的目录可能已被本轮其他目录的列表按 id 迁到新位置：换新位置再列一次
        for (id, triedURI) in missing {
            guard let record = try items.get(driveID: driveID, id: id), record.uri.description != triedURI,
                  let listing = try await listWholeFolder(id: id, parking: parking) else { continue }
            listings.append(listing)
        }
        for listing in listings {
            try items.removeUnseenChildren(
                driveID: driveID, parentID: listing.folderID, seen: listing.seen, unchangedAfter: listing.startSeq
            )
        }
    }

    /// 完整列出目录全部分页并更新镜像（不删除任何子项）；目录已不在镜像中、正被暂存或服务端按当前路径找不到时返回 nil。
    private func listWholeFolder(id: String, parking: CloudreveURI) async throws -> FolderListing? {
        let uri: CloudreveURI
        if id == rootID {
            uri = try folderURI(id: id)
        } else {
            guard let record = try items.get(driveID: driveID, id: id), record.isFolder,
                  !ItemStore.isWithin(record.uri.description, parking.description) else { return nil }
            uri = record.uri
        }
        let startSeq = try changeLog.latestSeq(driveID: driveID)
        var seen = Set<String>()
        var token: String?
        do {
            repeat {
                let (records, next) = try await listPage(folderID: id, uri: uri, serverToken: token, parking: parking)
                seen.formUnion(records.map(\.id))
                token = next
            } while token != nil
        } catch where Self.isNotFound(error) {
            return nil
        }
        try items.markEnumerated(driveID: driveID, id: id, at: now())
        return FolderListing(folderID: id, startSeq: startSeq, seen: seen)
    }

    private func applyUpsertEvent(_ event: FileEvent) async throws {
        let existing = try items.get(driveID: driveID, id: event.fileID)
        let info: FileResponse
        do {
            info = try await client.fileInfo(id: event.fileID)
        } catch where Self.isNotFound(error) {
            try removeLocally(existing.map { [$0] } ?? [])
            return
        }
        // 只有服务端完全没给 path 时才用事件路径兜底；给了但不是 `my`（如已移入回收站）即视为移出挂载根
        let uri: CloudreveURI?
        if let path = info.path {
            uri = Self.mountURI(path)
        } else {
            uri = CloudreveURI.join(root: try drive().remoteRootURI, relative: event.to ?? event.from)
        }
        // 移出挂载根，或移入尚未枚举的目录：删除本地旧位置，待该目录被枚举时再出现
        guard let uri, try isStrictlyInsideRoot(uri), let parentURI = uri.parent,
              let parentID = try parentID(forURI: parentURI) else {
            try removeLocally(existing.map { [$0] } ?? [])
            return
        }
        // 目录换位置时 store（upsert）在同一事务内清理目标占位并迁移后代
        try store(info, parentID: parentID, uri: uri)
    }

    /// 只按 id 定位：路径可能已被新条目占用，按路径兜底会误删新条目；
    /// 本地残留的旧行由 `reconcile()` 重列父目录时清理。
    private func applyDeleteEvent(_ event: FileEvent) throws {
        guard event.fileID != rootID, let record = try items.get(driveID: driveID, id: event.fileID) else { return }
        try removeLocally([record])
    }
}
