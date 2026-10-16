import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 应用 SSE 推送的远端事件，返回是否产生了变更日志。
    public func applyRemoteEvents(_ events: [FileEvent]) async throws -> Bool {
        try await run {
            let before = try self.changeLog.latestSeq(driveID: self.driveID)
            for event in events where event.fileID != self.rootID {
                switch event.type {
                case .create, .modify, .rename:
                    try await self.applyUpsertEvent(event)
                case .delete:
                    try self.applyDeleteEvent(event)
                }
            }
            return try self.changeLog.latestSeq(driveID: self.driveID) != before
        }
    }

    /// 重新完整列出所有曾枚举过的目录（兜底丢失的推送），返回是否产生了变更日志。
    public func reconcile() async throws -> Bool {
        try await run {
            let before = try self.changeLog.latestSeq(driveID: self.driveID)
            for folder in try self.items.enumeratedFolders(driveID: self.driveID) {
                try await self.relistFolder(id: folder.id)
            }
            try self.drives.updateLastReconcile(id: self.driveID)
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

    private func relistFolder(id: String) async throws {
        // 父目录本轮已删除该目录时跳过
        guard try id == rootID || items.get(driveID: driveID, id: id) != nil else { return }
        var token: String?
        repeat {
            do {
                token = try await enumerateFolder(id: id, pageToken: token).nextToken
            } catch SyncError.noSuchItem {
                return
            }
        } while token != nil
    }

    private func applyUpsertEvent(_ event: FileEvent) async throws {
        let existing = try items.get(driveID: driveID, id: event.fileID)
        let info: FileResponse
        do {
            info = try await client.fileInfo(id: event.fileID)
        } catch let error as CloudreveAPIError where [404, 40044].contains(error.serverCode ?? 0) {
            try removeLocally(existing.map { [$0] } ?? [])
            return
        }
        let root = try drive().remoteRootURI
        let uri = info.path.flatMap(CloudreveURI.init(string:))
            ?? CloudreveURI.join(root: root, relative: event.to ?? event.from)
        // 移出挂载根，或移入尚未枚举的目录：删除本地旧位置，待该目录被枚举时再出现
        guard uri != root, uri.isDescendant(ofOrEqualTo: root), let parentURI = uri.parent,
              let parentID = try parentID(forURI: parentURI) else {
            try removeLocally(existing.map { [$0] } ?? [])
            return
        }
        if let existing, existing.isFolder, existing.uri != uri {
            try items.reprefixURIs(driveID: driveID, oldPrefix: existing.uri, newPrefix: uri)
        }
        try store(info, parentID: parentID, uri: uri)
    }

    /// 优先按 id 定位（同路径可能已被新条目占用），找不到再按路径。
    private func applyDeleteEvent(_ event: FileEvent) throws {
        let root = try drive().remoteRootURI
        let record = try items.get(driveID: driveID, id: event.fileID)
            ?? items.getByURI(driveID: driveID, uri: CloudreveURI.join(root: root, relative: event.from))
        guard let record, record.id != rootID else { return }
        try removeLocally([record])
    }
}
