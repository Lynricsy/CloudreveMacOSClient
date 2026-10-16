import CloudreveAPI
import Foundation

/// 协议层错误 → 引擎错误。取消错误原样返回（调用方应重新抛出）。
public enum SyncErrorMapper {
    public static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is SyncError { return error }
        guard let apiError = error as? CloudreveAPIError else {
            return SyncError.cannotSynchronize(error.localizedDescription)
        }
        switch apiError {
        case .credentialInvalid:
            return SyncError.notAuthenticated
        case .transport:
            return SyncError.serverUnreachable
        case let .http(status, _) where status >= 500:
            return SyncError.serverUnreachable
        case let .server(code, message, _):
            return map(serverCode: code, message: message)
        case .unsupportedEncryption:
            return SyncError.cannotSynchronize("该存储策略要求客户端加密，暂不支持")
        default:
            return SyncError.cannotSynchronize(apiError.localizedDescription)
        }
    }

    private static func map(serverCode code: Int, message: String) -> SyncError {
        switch code {
        case 404, 40044: return .noSuchItem
        case 40004: return .filenameCollision
        case 40051: return .insufficientQuota
        case 40076: return .versionConflict
        case 401, 40020, 40089: return .notAuthenticated
        default: return .cannotSynchronize("服务器错误 \(code)：\(message)")
        }
    }
}
