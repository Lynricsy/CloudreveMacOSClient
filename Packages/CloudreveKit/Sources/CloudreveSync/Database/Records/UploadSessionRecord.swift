import Foundation
import GRDB

/// `upload_session` 表：断点续传用的上传会话（会话与分片进度以 JSON 文本存储）。
public struct UploadSessionRecord: SyncRecord, Equatable {
    public static let databaseTableName = "upload_session"

    public var driveID: String
    public var uri: String
    public var size: Int64
    public var policyType: String
    /// `UploadSession` 的 JSON。
    public var sessionJSON: String
    /// `chunksDone`（`[Int: String?]`）的 JSON。
    public var chunksJSON: String
    public var createdAt: Date

    public init(driveID: String, uri: String, size: Int64, policyType: String, sessionJSON: String, chunksJSON: String, createdAt: Date) {
        self.driveID = driveID
        self.uri = uri
        self.size = size
        self.policyType = policyType
        self.sessionJSON = sessionJSON
        self.chunksJSON = chunksJSON
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case uri, size
        case driveID = "drive_id"
        case policyType = "policy_type"
        case sessionJSON = "session_json"
        case chunksJSON = "chunks_json"
        case createdAt = "created_at"
    }
}
