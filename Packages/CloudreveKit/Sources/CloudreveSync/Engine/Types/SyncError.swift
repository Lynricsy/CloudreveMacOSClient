import Foundation

/// 引擎错误；扩展层一一映射为 NSFileProviderError。
public enum SyncError: Error, Sendable, Equatable {
    case notAuthenticated
    case serverUnreachable
    case noSuchItem
    /// 目标位置已有同名（大小写不敏感、Unicode 规范等价）条目；已知冲突条目时带上，供扩展构造冲突错误。
    case filenameCollision(existing: SyncItem?)
    case insufficientQuota
    case syncAnchorExpired
    case versionConflict
    case excludedFromSync
    case directoryNotEmpty
    /// 删除前服务端内容已变化（与系统给出的基准版本不同），拒绝删除。`latest` 为已写回镜像的服务端最新条目，
    /// 供扩展构造拒绝删除错误。
    case deletionRejected(latest: SyncItem?)
    case cannotSynchronize(String)
    /// 下载内容与服务端公布的摘要不符。服务端存储已损坏时重试也无法恢复，扩展需让系统退避而不是立即重下。
    case integrityCheckFailed(String)
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "登录已失效，请重新登录"
        case .serverUnreachable: return "无法连接服务器"
        case .noSuchItem: return "文件不存在"
        case .filenameCollision: return "同名文件已存在"
        case .insufficientQuota: return "存储空间不足"
        case .syncAnchorExpired: return "同步状态已过期"
        case .versionConflict: return "文件版本冲突"
        case .excludedFromSync: return "文件被忽略规则排除"
        case .directoryNotEmpty: return "目录不为空"
        case .deletionRejected: return "文件已在服务器上更改，未删除"
        case .cannotSynchronize(let message), .integrityCheckFailed(let message): return message
        }
    }
}
