import Foundation

/// 引擎错误；扩展层一一映射为 NSFileProviderError。
public enum SyncError: Error, Sendable, Equatable {
    case notAuthenticated
    case serverUnreachable
    case noSuchItem
    case filenameCollision
    case insufficientQuota
    case syncAnchorExpired
    case versionConflict
    case excludedFromSync
    case directoryNotEmpty
    case cannotSynchronize(String)
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
        case .cannotSynchronize(let message): return message
        }
    }
}
