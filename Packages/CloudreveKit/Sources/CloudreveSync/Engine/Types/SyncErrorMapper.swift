import CloudreveAPI
import Foundation

/// 协议层错误 → 引擎错误。
///
/// 暂时性故障（传输错误、HTTP 408/429/5xx、`URLError`）一律为 `.serverUnreachable`，系统会稍后重试；
/// `.cannotSynchronize` 只留给确定不会自行恢复的情况。取消错误、`SyncError` 以及非协议层错误
/// （本地文件、钥匙串等）原样返回，由扩展按错误域决定如何上报。
public enum SyncErrorMapper {
    public static func map(_ error: any Error) -> any Error {
        if error is CancellationError || error is SyncError { return error }
        if error is URLError { return SyncError.serverUnreachable }
        guard let apiError = error as? CloudreveAPIError else { return error }
        switch apiError {
        case .credentialInvalid:
            return SyncError.notAuthenticated
        case .transport:
            return SyncError.serverUnreachable
        case let .http(status, _) where status == 408 || status == 429 || status >= 500:
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
        case 40004: return .filenameCollision(existing: nil)
        case 40051: return .insufficientQuota
        case 40076: return .versionConflict
        case 401, 40020, 40089: return .notAuthenticated
        default: return .cannotSynchronize("服务器错误 \(code)：\(message)")
        }
    }
}
