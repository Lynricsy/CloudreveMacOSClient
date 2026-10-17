import Foundation

/// 分片上传器：创建/复用上传会话、并发上传分片（含重试与断点续传）、按策略完成上传。
public struct Uploader: Sendable {
    public typealias ProgressHandler = @Sendable (_ done: Int64, _ total: Int64) -> Void

    public let client: CloudreveClient
    public let store: any UploadProgressStore
    /// 每个分片在首次失败后的最大重试次数（退避 1s/2s/4s…）。
    public let maxRetries: Int
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date

    /// 又拍云无完成请求，上传后固定等待服务端回调。
    static let upyunCallbackDelay: Duration = .seconds(10)

    public init(
        client: CloudreveClient,
        store: any UploadProgressStore,
        maxRetries: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.store = store
        self.maxRetries = maxRetries
        self.sleep = sleep
        self.now = now
    }

    /// 上传本地文件到 `uri`。
    ///
    /// 错误处理：可重试错误（`.transport`、`.http(5xx)`）重试耗尽或任务取消时**保留**已持久化的会话，
    /// 下次调用可断点续传；其它错误删除本地会话记录后原样抛出（40076/40004/40051 等由同步层翻译）。
    public func upload(
        fileURL: URL, size: Int64, to uri: CloudreveURI, mimeType: String, lastModified: Date,
        overwrite: OverwriteMode, progress: @escaping ProgressHandler
    ) async throws -> FileResponse {
        if size == 0 { return try await uploadEmpty(to: uri, overwrite: overwrite) }
        let stored = try await prepareSession(size: size, uri: uri, mimeType: mimeType, lastModified: lastModified, overwrite: overwrite)
        do {
            let strategy = try StrategySelector.strategy(for: stored.session, fileSize: size)
            let etags = try await uploadPendingChunks(stored, fileURL: fileURL, strategy: strategy, progress: progress)
            try await strategy.complete(session: stored.session, etags: etags, client: client)
            if strategy is UpyunStrategy { try await sleep(Self.upyunCallbackDelay) }
            let file = try await client.fileInfo(uri: uri)
            try store.deleteSession(uri: stored.uri)
            Log.shared.info("upload", "上传完成：\(uri)（\(size) 字节）")
            return file
        } catch {
            if !Self.keepsSession(error) { try? store.deleteSession(uri: stored.uri) }
            Log.shared.error("upload", "上传失败：\(uri)：\(error)")
            throw error
        }
    }

    /// 0 字节文件不走上传会话。
    private func uploadEmpty(to uri: CloudreveURI, overwrite: OverwriteMode) async throws -> FileResponse {
        switch overwrite {
        case .create:
            return try await client.createItem(uri: uri, isFolder: false)
        case .version(let previous):
            return try await client.putContent(uri: uri, previous: previous, data: Data())
        }
    }

    /// 复用未过期、大小一致且创建于文件最后修改之后的已存会话（否则已传分片可能是旧内容），
    /// 其余情况（尽力）取消旧会话并新建。
    private func prepareSession(
        size: Int64, uri: CloudreveURI, mimeType: String, lastModified: Date, overwrite: OverwriteMode
    ) async throws -> StoredUploadSession {
        let key = uri.description
        if let existing = try store.loadSession(uri: key) {
            let unexpired = existing.session.expires > Int64(now().timeIntervalSince1970) + 60
            if existing.size == size, unexpired, existing.createdAt >= lastModified {
                Log.shared.info("upload", "复用上传会话 \(existing.session.sessionID)，已完成 \(existing.chunksDone.count) 块")
                return existing
            }
            try? await client.deleteUploadSession(id: existing.session.sessionID, uri: existing.uri)
            try store.deleteSession(uri: key)
        }
        let request = UploadSessionRequest(
            uri: key, size: size, lastModified: Int64(lastModified.timeIntervalSince1970 * 1000), mimeType: mimeType,
            entityType: overwrite.entityType, previous: overwrite.previous
        )
        let session = try await client.createUploadSession(request)
        if session.encryptMetadata != nil {
            try? await client.deleteUploadSession(id: session.sessionID, uri: key)
            throw CloudreveAPIError.unsupportedEncryption
        }
        let stored = StoredUploadSession(
            uri: key, size: size, policyType: session.storagePolicy?.type ?? "", session: session, createdAt: now()
        )
        try store.saveSession(stored)
        return stored
    }

    /// 并发上传未完成的分片，返回全部分片（含此前已完成的）etag。进度按分片内已发送字节回报。
    private func uploadPendingChunks(
        _ stored: StoredUploadSession, fileURL: URL, strategy: any ChunkStrategy, progress: @escaping ProgressHandler
    ) async throws -> [Int: String] {
        let chunks = UploadPlan.chunks(size: stored.size, chunkSize: stored.session.chunkSize)
        var etags = stored.chunksDone.compactMapValues { $0 }
        var pending = chunks.filter { stored.chunksDone[$0.index] == nil }[...]
        let completed = chunks.filter { stored.chunksDone[$0.index] != nil }.reduce(Int64(0)) { $0 + $1.length }
        let tracker = ChunkProgressTracker(completed: completed, total: stored.size, report: progress)
        tracker.reportCurrent()
        guard !pending.isEmpty else { return etags }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let concurrency = max(1, stored.session.storagePolicy?.chunkConcurrency ?? 1)
        try await withThrowingTaskGroup(of: (UploadChunk, String?).self) { group in
            func start(_ chunk: UploadChunk) throws {
                let data = try Self.read(chunk, from: handle)
                group.addTask {
                    let report: @Sendable (Int64) -> Void = { tracker.sent($0, of: chunk) }
                    let etag = try await UploadBodyProgress.$handler.withValue(report) {
                        try await uploadChunk(chunk, data: data, stored: stored, strategy: strategy)
                    }
                    return (chunk, etag)
                }
            }
            var running = 0
            while running < concurrency, let chunk = pending.popFirst() {
                try start(chunk)
                running += 1
            }
            while let (chunk, etag) = try await group.next() {
                if let etag { etags[chunk.index] = etag }
                tracker.completed(chunk)
                if let next = pending.popFirst() { try start(next) }
            }
        }
        return etags
    }

    /// 上传单个分片（带退避重试），成功后立即持久化进度。
    private func uploadChunk(
        _ chunk: UploadChunk, data: Data, stored: StoredUploadSession, strategy: any ChunkStrategy
    ) async throws -> String? {
        var attempt = 0
        while true {
            do {
                let etag = try await strategy.upload(chunk: chunk, data: data, session: stored.session, client: client)
                try store.markChunk(uri: stored.uri, index: chunk.index, etag: etag)
                return etag
            } catch {
                guard attempt < maxRetries, Self.isRetryable(error) else { throw error }
                Log.shared.info("upload", "分片 \(chunk.index) 失败，第 \(attempt + 1) 次重试：\(error)")
                try await sleep(.seconds(1 << attempt))
                attempt += 1
            }
        }
    }

    static func read(_ chunk: UploadChunk, from handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: UInt64(chunk.offset))
        let data = try handle.read(upToCount: Int(chunk.length)) ?? Data()
        guard data.count == Int(chunk.length) else { throw CloudreveAPIError.transport("short read") }
        return data
    }

    /// 仅网络错误与 5xx 可重试。
    static func isRetryable(_ error: any Error) -> Bool {
        switch error as? CloudreveAPIError {
        case .transport: return true
        case .http(let status, _): return status >= 500
        default: return false
        }
    }

    /// 可重试错误（重试已耗尽）与取消保留会话以便续传。
    static func keepsSession(_ error: any Error) -> Bool {
        error is CancellationError || isRetryable(error)
    }
}

extension OverwriteMode {
    var entityType: String? {
        if case .version = self { return "version" }
        return nil
    }

    var previous: String? {
        if case .version(let previous) = self { return previous }
        return nil
    }
}
