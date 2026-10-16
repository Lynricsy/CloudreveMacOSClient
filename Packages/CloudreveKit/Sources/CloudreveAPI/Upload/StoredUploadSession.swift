import Foundation

/// 已持久化的上传会话及已完成分片。
public struct StoredUploadSession: Codable, Sendable, Equatable {
    public var uri: String
    public var size: Int64
    public var policyType: String
    public var session: UploadSession
    /// 已完成分片：index → etag（无 etag 的策略为 nil）。
    public var chunksDone: [Int: String?]
    public var createdAt: Date

    public init(uri: String, size: Int64, policyType: String, session: UploadSession, chunksDone: [Int: String?] = [:], createdAt: Date) {
        self.uri = uri
        self.size = size
        self.policyType = policyType
        self.session = session
        self.chunksDone = chunksDone
        self.createdAt = createdAt
    }
}
