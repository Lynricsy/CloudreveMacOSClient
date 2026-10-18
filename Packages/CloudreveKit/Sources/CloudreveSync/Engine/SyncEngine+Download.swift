import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 下载条目内容到 `destination`（调用方给出的临时文件路径）。
    ///
    /// `version` 为 nil 时下载镜像中的当前版本；否则下载指定 entity（即使等于镜像当前版本），返回条目的内容版本与大小
    /// 描述实际写入的内容（File Provider 要求返回版本与请求一致），指定版本取不到时抛错，绝不换成另一个版本。
    /// 未指定版本且当前版本取不到（服务端已清理旧 entity 或文件已移动）时按 id 刷新镜像并重下新版本；只有文件确实已不存在
    /// 才报 `.noSuchItem`（系统据此删除本地条目），文件被移进镜像尚未见过的目录时补查祖先目录。
    /// 成功返回前 `destination` 尚未交付给系统：任何失败（含取消）都删除该文件。
    public func download(id: String, version: String?, to destination: URL, progress: @escaping ProgressHandler) async throws -> SyncItem {
        try await run {
            let record = try self.localRecord(id: id)
            guard !record.isFolder else { throw SyncError.cannotSynchronize("目录没有内容") }
            let transfer = TransferProgress(
                store: self.transfers, driveID: self.driveID, kind: .download, itemID: record.id, name: record.name,
                uri: record.uri.description, total: record.size, now: self.now
            )
            do {
                let item: SyncItem
                if let requested = Self.nonEmpty(version) {
                    item = try await self.downloadVersion(requested, of: record, to: destination, transfer: transfer, progress: progress)
                } else {
                    item = try await self.downloadCurrent(record, to: destination, transfer: transfer, progress: progress)
                }
                transfer.finish(error: nil)
                return item
            } catch {
                try? FileManager.default.removeItem(at: destination)
                transfer.finish(error: Self.describe(error))
                throw error
            }
        }
    }

    /// 指定的历史版本：只有内容版本与大小取自实际写入的内容，镜像不变。
    private func downloadVersion(
        _ entity: String, of record: ItemRecord, to destination: URL, transfer: TransferProgress, progress: @escaping ProgressHandler
    ) async throws -> SyncItem {
        let written: Int64
        do {
            written = try await fetchContent(record, entity: entity, to: destination, transfer: transfer, progress: progress)
        } catch where Self.isNotFound(error) {
            // 指定的历史版本不存在不代表条目被删除，不能报 noSuchItem（系统会据此删除本地条目）
            throw SyncError.cannotSynchronize("请求的版本已不存在")
        }
        // 只有镜像当前版本才知道期望长度
        if entity == record.entityID, written != record.size {
            throw SyncError.cannotSynchronize("下载长度不符")
        }
        var item = SyncItem(record: record)
        item.entityID = entity
        item.size = written
        return item
    }

    /// 镜像中的当前版本；取不到时按 id 刷新后重试一次。
    private func downloadCurrent(
        _ record: ItemRecord, to destination: URL, transfer: TransferProgress, progress: @escaping ProgressHandler
    ) async throws -> SyncItem {
        do {
            try await fetchCurrent(record, to: destination, transfer: transfer, progress: progress)
            return SyncItem(record: record)
        } catch where Self.isNotFound(error) {
            guard let remote = try await remoteItem(id: record.id), !remote.file.isFolder else {
                try removeLocally([record])
                throw SyncError.noSuchItem
            }
            guard let parentURI = remote.uri.parent, let parentID = try await resolveFolderID(forURI: parentURI) else {
                // 文件仍存在，只是暂时定位不到父目录：保留记录，不得报 noSuchItem
                throw SyncError.cannotSynchronize("文件所在目录暂时无法定位")
            }
            let refreshed = ItemRecord(file: remote.file, driveID: driveID, parentID: parentID, uri: remote.uri)
            guard refreshed.entityID != record.entityID || refreshed.uri.description != record.uri.description else {
                throw SyncError.cannotSynchronize("文件当前版本暂时无法下载")
            }
            try items.upsert([refreshed])
            try await fetchCurrent(refreshed, to: destination, transfer: transfer, progress: progress)
            return SyncItem(record: refreshed)
        }
    }

    private func fetchCurrent(
        _ record: ItemRecord, to destination: URL, transfer: TransferProgress, progress: @escaping ProgressHandler
    ) async throws {
        let entity = Self.nonEmpty(record.entityID)
        let written = try await fetchContent(record, entity: entity, to: destination, transfer: transfer, progress: progress)
        guard written == record.size else { throw SyncError.cannotSynchronize("下载长度不符") }
    }

    /// 缩略图地址；目录、混淆缩略图或服务端不支持该类型时返回 nil。
    public func thumbnailURL(id: String) async throws -> URL? {
        try await run {
            let record = try self.localRecord(id: id)
            guard !record.isFolder else { return nil }
            let thumb: ThumbResponse
            do {
                thumb = try await self.client.thumbnail(uri: record.uri)
            } catch let error as CloudreveAPIError where Self.isUnsupportedThumbnail(error) {
                return nil
            }
            guard thumb.obfuscated != true else { return nil }
            return URL(string: thumb.url, relativeTo: self.client.site)?.absoluteURL
        }
    }

    /// 业务错误（非凭证失效）说明该文件没有可用缩略图。
    static func isUnsupportedThumbnail(_ error: CloudreveAPIError) -> Bool {
        guard let code = error.serverCode else { return false }
        return !CloudreveAPIError.credentialCodes.contains(code)
    }

    /// 流式写入文件，返回写入字节数。空文件不访问网络。
    private func fetchContent(
        _ record: ItemRecord, entity: String?, to destination: URL, transfer: TransferProgress,
        progress: @escaping ProgressHandler
    ) async throws -> Int64 {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SyncError.cannotSynchronize("无法创建临时文件")
        }
        if record.size == 0 && entity == nil { return 0 }
        let url = try await client.downloadURL(uri: record.uri, entity: entity)
        let (head, chunks) = try await client.fetch(url: url)
        guard (200..<300).contains(head.status) else {
            throw CloudreveAPIError.http(status: head.status, body: try await CloudreveClient.collect(chunks))
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        for try await chunk in chunks {
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            transfer.report(written)
            progress(written, record.size)
        }
        return written
    }
}
