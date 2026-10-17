import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 下载条目内容到 `destination`（调用方给出的临时文件路径）。
    ///
    /// 返回的条目必须描述写入的内容。系统请求的版本与本地镜像不一致时（远端已更新而系统仍持旧版本，或反之），
    /// 先按 id 从服务端刷新镜像，再下载服务端当前版本；条目已被删除或移出挂载根时抛出 `noSuchItem`。
    public func download(id: String, version: String?, to destination: URL, progress: @escaping ProgressHandler) async throws -> SyncItem {
        try await run {
            var record = try self.localRecord(id: id)
            guard !record.isFolder else { throw SyncError.cannotSynchronize("目录没有内容") }
            if let requested = version, !requested.isEmpty, requested != record.entityID {
                try await self.refreshItem(id: id, fallbackURI: record.uri)
                record = try self.localRecord(id: id)
            }
            let entity = record.entityID.isEmpty ? nil : record.entityID
            let transfer = TransferProgress(
                store: self.transfers, driveID: self.driveID, kind: .download, itemID: record.id, name: record.name,
                uri: record.uri.description, total: record.size, now: self.now
            )
            do {
                let written = try await self.fetchContent(record, entity: entity, to: destination, transfer: transfer, progress: progress)
                if written != record.size {
                    try? FileManager.default.removeItem(at: destination)
                    throw SyncError.cannotSynchronize("下载长度不符")
                }
                transfer.finish(error: nil)
                return SyncItem(record: record)
            } catch {
                transfer.finish(error: Self.describe(error))
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
