import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 新建目录。名称转为 NFC 发往服务端；目标目录在镜像中已有大小写不敏感且规范等价的其他条目时抛
    /// `.filenameCollision(existing:)`。`mayAlreadyExist` 时同名目录视为已创建，同名文件仍是冲突。
    public func createFolder(name: String, parentID: String, mayAlreadyExist: Bool) async throws -> SyncItem {
        try await run {
            let name = Self.normalizedName(name)
            try self.checkNameAvailable(name, in: parentID, excluding: nil, allowSameName: mayAlreadyExist)
            let uri = try self.folderURI(id: parentID).appending(name)
            let file: FileResponse
            do {
                file = try await self.client.createItem(uri: uri, isFolder: true)
            } catch let error as CloudreveAPIError where error.serverCode == 40004 {
                let existing = await self.knownOccupant(at: uri, parentID: parentID)
                guard mayAlreadyExist, let existing, existing.isFolder else { throw SyncError.filenameCollision(existing: existing) }
                return existing
            }
            return try self.store(file, parentID: parentID, uri: uri)
        }
    }

    /// 新建文件（`contents` 为 nil 表示空文件）。名称规则同 `createFolder`。
    ///
    /// `mayAlreadyExist`（系统重新导入）命中服务端同名文件时：本地内容与服务端逐字节相同才认领服务端条目，
    /// 否则抛 `.filenameCollision(existing:)`，不得把服务端版本当成上传成功；没有本地内容时只认领服务端已有的同名文件，
    /// 服务端没有可匹配条目则返回 nil（不凭空新建空文件）。
    public func createFile(
        name: String, parentID: String, contents: URL?, mtime: Date, mayAlreadyExist: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> SyncItem? {
        try await run {
            let name = Self.normalizedName(name)
            guard !IgnoreRules(userPatterns: try self.drive().ignorePatterns).matches(name: name) else {
                throw SyncError.excludedFromSync
            }
            try self.checkNameAvailable(name, in: parentID, excluding: nil, allowSameName: mayAlreadyExist)
            let uri = try self.folderURI(id: parentID).appending(name)
            if contents == nil, mayAlreadyExist {
                return try await self.claimExistingFile(at: uri, parentID: parentID)
            }
            let transfer = try self.makeTransfer(uri: uri, itemID: nil, contents: contents)
            let item: SyncItem
            do {
                do {
                    let file = try await self.upload(contents: contents, to: uri, mtime: mtime, overwrite: .create,
                                                     transfer: transfer, progress: progress)
                    item = try self.store(file, parentID: parentID, uri: uri)
                } catch let error as CloudreveAPIError where error.serverCode == 40004 {
                    item = try await self.adoptExistingFile(
                        at: uri, parentID: parentID, contents: contents, mayAlreadyExist: mayAlreadyExist
                    )
                }
            } catch {
                transfer.finish(error: Self.describe(error))
                throw error
            }
            transfer.finish(error: nil)
            return item
        }
    }

    public func rename(id: String, newName: String) async throws -> SyncItem {
        try await run { try await self.renameItem(id: id, newName: newName) }
    }

    public func move(id: String, toParentID: String) async throws -> SyncItem {
        try await run { try await self.moveItem(id: id, toParentID: toParentID) }
    }

    /// 删除远端条目；远端已不存在（或已移出挂载根）视为成功，只删除本地记录。
    /// 先按 id 解析服务端当前路径：镜像路径可能已过期，原路径甚至可能已被另一个条目占用。
    /// `baseContentVersion` 非 nil 且是文件时，服务端当前内容版本不同（别处改过）则抛 `.deletionRejected`。
    /// `recursive == false` 且远端目录仍有子项（可能是本地尚未见到的远端新增）时抛 `.directoryNotEmpty`，
    /// 避免连带删除用户未见过的文件。
    public func delete(id: String, recursive: Bool = true, baseContentVersion: String? = nil) async throws {
        try await run {
            guard id != self.rootID else { throw SyncError.cannotSynchronize("不能删除云盘根目录") }
            guard let record = try self.items.get(driveID: self.driveID, id: id) else { return }
            if let remote = try await self.remoteItem(id: id) {
                if let base = Self.nonEmpty(baseContentVersion), !remote.file.isFolder, remote.file.primaryEntity ?? "" != base {
                    // 先把服务端最新条目写回镜像（产生 update），系统据此拿到新版本而不是保留过期条目
                    throw SyncError.deletionRejected(latest: try await self.storeRemote(remote))
                }
                do {
                    if remote.file.isFolder, !recursive {
                        let children = try await self.client.listFiles(uri: remote.uri, pageSize: 1)
                        if !children.files.isEmpty { throw SyncError.directoryNotEmpty }
                    }
                    try await self.client.delete(uris: [remote.uri])
                } catch where Self.isNotFound(error) {
                    Log.shared.info("engine", "远端已删除：\(remote.uri)")
                }
            } else {
                Log.shared.info("engine", "远端已不存在或已移出挂载根：\(record.uri)")
            }
            try self.removeLocally([record])
        }
    }

    // MARK: - 内部实现（不经 run 包装，供 modify 组合）

    func renameItem(id: String, newName: String) async throws -> SyncItem {
        let record = try localRecord(id: id)
        let name = Self.normalizedName(newName)
        guard !Self.sameScalars(record.name, name) else { return SyncItem(record: record) }
        guard record.parentID != nil else { throw SyncError.cannotSynchronize("不能重命名云盘根目录") }
        // 冲突检查用服务端当前的父目录：镜像中的位置可能已过期
        let location = try await currentLocation(of: record)
        guard !Self.sameScalars(location.file.name, name) else {
            return try store(location.file, parentID: location.parentID, uri: location.uri)
        }
        try checkNameAvailable(name, in: location.parentID, excluding: id)
        let file: FileResponse
        do {
            file = try await client.rename(uri: location.uri, newName: name)
        } catch let error as CloudreveAPIError where error.serverCode == 40004 {
            let target = location.parentURI.appending(name)
            throw SyncError.filenameCollision(existing: await knownOccupant(at: target, parentID: location.parentID))
        }
        // 目录换名时 store（upsert）在同一事务内迁移后代
        return try store(file, parentID: location.parentID, uri: location.parentURI.appending(file.name))
    }

    func moveItem(id: String, toParentID: String) async throws -> SyncItem {
        let record = try localRecord(id: id)
        guard record.parentID != toParentID else { return SyncItem(record: record) }
        let location = try await currentLocation(of: record)
        guard location.parentID != toParentID else {
            return try store(location.file, parentID: location.parentID, uri: location.uri)
        }
        // 冲突检查用服务端当前名称：镜像中的名称可能已过期
        try checkNameAvailable(location.file.name, in: toParentID, excluding: id)
        let destination = try await currentFolderURI(id: toParentID)
        do {
            try await client.move(uris: [location.uri], to: destination)
        } catch let error as CloudreveAPIError where error.serverCode == 40004 {
            let target = destination.appending(location.uri.lastPathComponent)
            throw SyncError.filenameCollision(existing: await knownOccupant(at: target, parentID: toParentID))
        }
        let file = try await client.fileInfo(id: id)
        return try store(file, parentID: toParentID, uri: destination.appending(file.name))
    }

    /// 条目在服务端的当前状态与位置。
    struct RemoteLocation {
        let file: FileResponse
        let uri: CloudreveURI
        let parentURI: CloudreveURI
        let parentID: String
    }

    /// 按 id 解析条目在服务端的当前位置（父目录不在镜像中时逐级补查）。已不存在或已移出挂载根时删除本地记录并抛
    /// `.noSuchItem`。
    func currentLocation(of record: ItemRecord) async throws -> RemoteLocation {
        guard let remote = try await remoteItem(id: record.id), let parentURI = remote.uri.parent,
              let parentID = try await resolveFolderID(forURI: parentURI) else {
            try removeLocally([record])
            throw SyncError.noSuchItem
        }
        return RemoteLocation(file: remote.file, uri: remote.uri, parentURI: parentURI, parentID: parentID)
    }

    /// 目录 id → 服务端当前路径（根为挂载根）。镜像中的路径可能已过期（远端改名或移动后原路径被占用），按 id 查询并刷新镜像；
    /// 已不存在、已移出挂载根或不是目录时抛 `.noSuchItem`。
    func currentFolderURI(id: String) async throws -> CloudreveURI {
        if id == rootID { return try drive().remoteRootURI }
        guard let remote = try await remoteItem(id: id), remote.file.isFolder else { throw SyncError.noSuchItem }
        _ = try await storeRemote(remote)
        return remote.uri
    }

    /// 把按 id 查到的服务端条目写入镜像（父目录不在镜像中时逐级补查）；父目录无法定位时返回 nil。
    func storeRemote(_ remote: (file: FileResponse, uri: CloudreveURI)) async throws -> SyncItem? {
        guard let parentURI = remote.uri.parent, let parentID = try await resolveFolderID(forURI: parentURI) else { return nil }
        return try store(remote.file, parentID: parentID, uri: remote.uri)
    }

    /// 目标目录在镜像中已有与 `name` 大小写不敏感且 Unicode 规范等价的其他条目（不含 `id` 自身）时抛
    /// `.filenameCollision(existing:)`。`allowSameName` 时名称逐标量完全相同的条目留给服务端按「可能已存在」处理。
    func checkNameAvailable(_ name: String, in parentID: String, excluding id: String?, allowSameName: Bool = false) throws {
        let key = Self.collisionKey(name)
        for sibling in try items.children(driveID: driveID, parentID: parentID) where sibling.id != id {
            guard Self.collisionKey(sibling.name) == key else { continue }
            if allowSameName, Self.sameScalars(sibling.name, name) { continue }
            throw SyncError.filenameCollision(existing: SyncItem(record: sibling))
        }
    }

    /// 服务端报同名冲突时取回占用该位置的条目并写入镜像（供扩展构造冲突错误）；取不到时为 nil。
    func knownOccupant(at uri: CloudreveURI, parentID: String) async -> SyncItem? {
        guard let file = try? await client.fileInfo(uri: uri) else { return nil }
        return try? store(file, parentID: parentID, uri: uri)
    }

    /// 没有本地内容的重新导入：认领服务端已有的同名文件；没有（或同名的是目录）时返回 nil。
    private func claimExistingFile(at uri: CloudreveURI, parentID: String) async throws -> SyncItem? {
        let file: FileResponse
        do {
            file = try await client.fileInfo(uri: uri)
        } catch where Self.isNotFound(error) {
            return nil
        }
        guard !file.isFolder else { return nil }
        return try store(file, parentID: parentID, uri: uri)
    }

    /// 上传因同名被拒：仅当允许已存在、服务端是文件且内容与本地逐字节相同时认领服务端条目，否则报冲突。
    private func adoptExistingFile(
        at uri: CloudreveURI, parentID: String, contents: URL?, mayAlreadyExist: Bool
    ) async throws -> SyncItem {
        let existing = await knownOccupant(at: uri, parentID: parentID)
        guard mayAlreadyExist, let existing, !existing.isFolder, let contents,
              try await remoteContent(of: existing, equals: contents) else {
            throw SyncError.filenameCollision(existing: existing)
        }
        return existing
    }

    /// 服务端当前内容是否与本地文件逐字节相同（流式比较，遇到差异即停止）。
    private func remoteContent(of item: SyncItem, equals local: URL) async throws -> Bool {
        let size = try Self.fileSize(of: local)
        guard size == item.size else { return false }
        guard size > 0 else { return true }
        let url = try await client.downloadURL(uri: item.uri, entity: Self.nonEmpty(item.entityID))
        let (head, chunks) = try await client.fetch(url: url)
        guard (200..<300).contains(head.status) else {
            throw CloudreveAPIError.http(status: head.status, body: try await CloudreveClient.collect(chunks))
        }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        for try await chunk in chunks where !chunk.isEmpty {
            guard try handle.read(upToCount: chunk.count) == chunk else { return false }
        }
        return try handle.read(upToCount: 1)?.isEmpty ?? true
    }

    /// 为一次上传创建传输活动记录。
    func makeTransfer(uri: CloudreveURI, itemID: String?, contents: URL?) throws -> TransferProgress {
        TransferProgress(
            store: transfers, driveID: driveID, kind: .upload, itemID: itemID, name: uri.lastPathComponent,
            uri: uri.description, total: try contents.map(Self.fileSize(of:)) ?? 0, now: now
        )
    }

    /// 上传本地内容（nil 视为空文件），进度同时写入传输记录；结束状态由调用方写入。
    func upload(
        contents: URL?, to uri: CloudreveURI, mtime: Date, overwrite: OverwriteMode,
        transfer: TransferProgress, progress: @escaping ProgressHandler
    ) async throws -> FileResponse {
        try await uploader.upload(
            fileURL: contents ?? URL(fileURLWithPath: "/dev/null"), size: transfer.total, to: uri,
            mimeType: MIMETypes.guess(fileName: uri.lastPathComponent), lastModified: mtime, overwrite: overwrite
        ) { done, total in
            transfer.report(done)
            progress(done, total)
        }
    }

    static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 写入传输记录的错误描述（中文）。
    static func describe(_ error: any Error) -> String {
        SyncErrorMapper.map(error).localizedDescription
    }

    // MARK: - 名称

    /// 发往服务端的名称统一为 NFC。
    static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// 逐个 Unicode 标量比较。Swift `String ==` 按规范等价比较，会把仅规范化形式不同的改名当成未改名。
    static func sameScalars(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    /// 同名判定键：大小写不敏感且 Unicode 规范等价的名称得到相同的标量序列（与 macOS 默认文件系统的同名规则一致）。
    static func collisionKey(_ name: String) -> [Unicode.Scalar] {
        let folded = name.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
        return Array(folded.precomposedStringWithCanonicalMapping.unicodeScalars)
    }

    static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
