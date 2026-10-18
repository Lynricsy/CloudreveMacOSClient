import Foundation

/// 某种存储策略的分片上传协议。
///
/// 收尾分两步并由上传器分别持久化：`merge`（存储侧合并分片）与 `commit`（通知 Cloudreve 完成）。
/// 回调失败后续传只补发 `commit`，不会重复合并已完成的存储会话。
public protocol ChunkStrategy: Sendable {
    /// 上传一个分片，返回该分片的 etag（无需 etag 的策略返回 nil）。
    /// `body` 为分片内容；上传器传入磁盘暂存文件（`.file`），内存占用与分片大小无关。
    func upload(chunk: UploadChunk, body: HTTPBody, session: UploadSession, client: CloudreveClient) async throws -> String?
    /// 全部分片上传完成后的存储侧合并（无需合并的策略为空实现）。`etags`：分片序号 → etag。
    func merge(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws
    /// 通知 Cloudreve 上传完成（由存储自行回调服务端或末块自动完成的策略为空实现）。
    func commit(session: UploadSession, client: CloudreveClient) async throws
    /// 上一次合并请求已发出但结果未确认时，重发合并得到 `error` 是否说明分片其实已被合并。
    /// 是则跳过合并、交给 `commit` 由服务端确认。
    func indicatesEarlierMerge(_ error: any Error) -> Bool
}

extension ChunkStrategy {
    public func merge(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {}
    public func commit(session: UploadSession, client: CloudreveClient) async throws {}
    public func indicatesEarlierMerge(_ error: any Error) -> Bool { false }
}
