import Foundation

/// 上传会话进度持久化（断点续传）。按 URI 区分会话；实现方负责按云盘隔离作用域。
public protocol UploadProgressStore: Sendable {
    func loadSession(uri: String) throws -> StoredUploadSession?
    func saveSession(_ session: StoredUploadSession) throws
    /// 记录分片完成；`etag` 仅 S3 系/七牛需要。
    func markChunk(uri: String, index: Int, etag: String?) throws
    func deleteSession(uri: String) throws
}
