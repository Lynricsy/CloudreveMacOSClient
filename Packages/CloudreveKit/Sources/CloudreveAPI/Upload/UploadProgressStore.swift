import Foundation

/// 上传会话进度持久化（断点续传）。按 URI 区分会话；实现方负责按云盘隔离作用域。
public protocol UploadProgressStore: Sendable {
    func loadSession(uri: String) throws -> StoredUploadSession?
    func saveSession(_ session: StoredUploadSession) throws
    /// 记录分片完成；`etag` 仅 S3 系/七牛需要，`digest` 为该分片实际上传内容的 SHA-256（十六进制）。
    func markChunk(uri: String, index: Int, etag: String?, digest: String) throws
    /// 记录收尾阶段（只前进不后退）。
    func markStage(uri: String, stage: UploadStage) throws
    func deleteSession(uri: String) throws
}
