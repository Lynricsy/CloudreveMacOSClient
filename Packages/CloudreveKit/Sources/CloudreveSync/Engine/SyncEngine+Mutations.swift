import CloudreveAPI
import Foundation

extension SyncEngine {
    public func createFolder(name: String, parentID: String, mayAlreadyExist: Bool) async throws -> SyncItem {
        try await run {
            let uri = try self.folderURI(id: parentID).appending(name)
            let file: FileResponse
            do {
                file = try await self.client.createItem(uri: uri, isFolder: true)
            } catch let error as CloudreveAPIError where error.serverCode == 40004 {
                guard mayAlreadyExist else { throw SyncError.filenameCollision }
                file = try await self.client.fileInfo(uri: uri)
            }
            return try self.store(file, parentID: parentID, uri: uri)
        }
    }

    public func createFile(
        name: String, parentID: String, contents: URL?, mtime: Date, mayAlreadyExist: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> SyncItem {
        try await run {
            guard !IgnoreRules(userPatterns: try self.drive().ignorePatterns).matches(name: name) else {
                throw SyncError.excludedFromSync
            }
            let uri = try self.folderURI(id: parentID).appending(name)
            let transfer = try self.makeTransfer(uri: uri, itemID: nil, contents: contents)
            let file: FileResponse
            do {
                file = try await self.upload(contents: contents, to: uri, mtime: mtime, overwrite: .create,
                                             transfer: transfer, progress: progress)
                transfer.finish(error: nil)
            } catch let error as CloudreveAPIError where error.serverCode == 40004 && mayAlreadyExist {
                // 系统重新导入已存在的条目：以服务端现有文件为准
                file = try await self.client.fileInfo(uri: uri)
                transfer.finish(error: nil)
            } catch {
                transfer.finish(error: Self.describe(error))
                throw error
            }
            return try self.store(file, parentID: parentID, uri: uri)
        }
    }

    public func rename(id: String, newName: String) async throws -> SyncItem {
        try await run { try await self.renameItem(id: id, newName: newName) }
    }

    public func move(id: String, toParentID: String) async throws -> SyncItem {
        try await run { try await self.moveItem(id: id, toParentID: toParentID) }
    }

    /// 删除远端条目；远端已不存在视为成功。
    /// `recursive == false` 且远端目录仍有子项（可能是本地尚未见到的远端新增）时抛 `.directoryNotEmpty`，
    /// 避免连带删除用户未见过的文件。
    public func delete(id: String, recursive: Bool = true) async throws {
        try await run {
            guard id != self.rootID else { throw SyncError.cannotSynchronize("不能删除云盘根目录") }
            guard let record = try self.items.get(driveID: self.driveID, id: id) else { return }
            do {
                if record.isFolder, !recursive {
                    let children = try await self.client.listFiles(uri: record.uri, pageSize: 1)
                    if !children.files.isEmpty { throw SyncError.directoryNotEmpty }
                }
                try await self.client.delete(uris: [record.uri])
            } catch let error as CloudreveAPIError where [404, 40044].contains(error.serverCode ?? 0) {
                Log.shared.info("engine", "远端已删除：\(record.uri)")
            }
            try self.removeLocally([record])
        }
    }

    // MARK: - 内部实现（不经 run 包装，供 modify 组合）

    func renameItem(id: String, newName: String) async throws -> SyncItem {
        let record = try localRecord(id: id)
        guard record.name != newName else { return SyncItem(record: record) }
        guard let parentURI = record.uri.parent, let parentID = record.parentID else {
            throw SyncError.cannotSynchronize("不能重命名云盘根目录")
        }
        let file = try await client.rename(uri: record.uri, newName: newName)
        let newURI = parentURI.appending(file.name)
        if record.isFolder {
            try items.reprefixURIs(driveID: driveID, oldPrefix: record.uri, newPrefix: newURI)
        }
        return try store(file, parentID: parentID, uri: newURI)
    }

    func moveItem(id: String, toParentID: String) async throws -> SyncItem {
        let record = try localRecord(id: id)
        guard record.parentID != toParentID else { return SyncItem(record: record) }
        let destination = try folderURI(id: toParentID)
        try await client.move(uris: [record.uri], to: destination)
        let newURI = destination.appending(record.name)
        let file = try await client.fileInfo(uri: newURI)
        if record.isFolder {
            try items.reprefixURIs(driveID: driveID, oldPrefix: record.uri, newPrefix: newURI)
        }
        return try store(file, parentID: toParentID, uri: newURI)
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
}
