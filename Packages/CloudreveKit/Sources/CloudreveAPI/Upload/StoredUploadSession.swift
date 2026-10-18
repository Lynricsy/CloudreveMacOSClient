import Foundation

/// 已持久化的上传会话及续传状态。
public struct StoredUploadSession: Codable, Sendable, Equatable {
    public var uri: String
    public var size: Int64
    public var policyType: String
    public var session: UploadSession
    /// 创建会话时的覆盖方式（含 previous）；nil 表示未知（旧版本记录），不得复用。
    public var overwrite: OverwriteMode?
    /// 已完成分片：index → etag（无 etag 的策略为 nil）。
    public var chunksDone: [Int: String?]
    /// 已完成分片实际上传内容的 SHA-256（小写十六进制）：复用会话前与本地文件对应范围逐一比对。
    public var chunkDigests: [Int: String]
    /// 已确认的收尾阶段，续传时从下一步开始。
    public var stage: UploadStage
    public var createdAt: Date

    public init(
        uri: String, size: Int64, policyType: String, session: UploadSession, overwrite: OverwriteMode? = nil,
        chunksDone: [Int: String?] = [:], chunkDigests: [Int: String] = [:], stage: UploadStage = .uploading,
        createdAt: Date
    ) {
        self.uri = uri
        self.size = size
        self.policyType = policyType
        self.session = session
        self.overwrite = overwrite
        self.chunksDone = chunksDone
        self.chunkDigests = chunkDigests
        self.stage = stage
        self.createdAt = createdAt
    }
}

/// 上传收尾阶段（按先后顺序）。
public enum UploadStage: String, Codable, Sendable, Comparable {
    /// 分片上传中。
    case uploading
    /// 存储侧合并请求已发出，结果未确认（响应可能丢失）。
    case merging
    /// 存储侧合并已确认完成。
    case merged
    /// Cloudreve 已确认上传完成（回调成功）。
    case committed

    private var order: Int {
        switch self {
        case .uploading: 0
        case .merging: 1
        case .merged: 2
        case .committed: 3
        }
    }

    public static func < (lhs: UploadStage, rhs: UploadStage) -> Bool {
        lhs.order < rhs.order
    }
}
