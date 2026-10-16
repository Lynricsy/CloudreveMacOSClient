import Foundation

/// 某种存储策略的分片上传协议。
public protocol ChunkStrategy: Sendable {
    /// 上传一个分片，返回该分片的 etag（无需 etag 的策略返回 nil）。
    func upload(chunk: UploadChunk, data: Data, session: UploadSession, client: CloudreveClient) async throws -> String?
    /// 全部分片上传完成后的收尾（合并分片、回调服务端等）。`etags`：分片序号 → etag。
    func complete(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws
}
