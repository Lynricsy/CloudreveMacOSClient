import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 下载条目内容到 `destination`（调用方给出的临时文件路径）。
    ///
    /// `version` 为 nil 时下载镜像中的当前版本；否则下载指定 entity，返回条目的内容版本与大小描述实际写入的内容
    /// （File Provider 要求返回版本与请求一致），指定版本取不到时抛错。不修改镜像。
    public func download(id: String, version: String?, to destination: URL, progress: @escaping ProgressHandler) async throws -> SyncItem {
        try await run {
            let record = try self.localRecord(id: id)
            guard !record.isFolder else { throw SyncError.cannotSynchronize("目录没有内容") }
            let requested = version.flatMap { $0.isEmpty ? nil : $0 }
            let entity = requested ?? (record.entityID.isEmpty ? nil : record.entityID)
            let isCurrent = entity == nil || entity == record.entityID
            let transfer = TransferProgress(
                store: self.transfers, driveID: self.driveID, kind: .download, itemID: record.id, name: record.name,
                uri: record.uri.description, total: record.size, now: self.now
            )
            do {
                let written = try await self.fetchContent(record, entity: entity, to: destination, transfer: transfer, progress: progress)
                // 只有当前版本才知道期望长度
                if isCurrent, written != record.size {
                    try? FileManager.default.removeItem(at: destination)
                    throw SyncError.cannotSynchronize("下载长度不符")
                }
                transfer.finish(error: nil)
                var item = SyncItem(record: record)
                if let entity, !isCurrent {
                    item.entityID = entity
                    item.size = written
                }
                return item
            } catch {
                transfer.finish(error: Self.describe(error))
                // 指定的历史版本不存在不代表条目被删除，不能报 noSuchItem（系统会据此删除本地条目）
                if !isCurrent, case SyncError.noSuchItem? = SyncErrorMapper.map(error) as? SyncError {
                    throw SyncError.cannotSynchronize("请求的版本已不存在")
                }
                throw error
            }
        }
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
