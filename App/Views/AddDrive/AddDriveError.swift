import CloudreveAPI
import Foundation

/// 添加 / 重新登录云盘流程中的业务错误。
enum AddDriveError: LocalizedError, Sendable, Equatable {
    case invalidSiteURL
    case serverTooOld(String)
    case unrecognizedVersion(String)
    case notAFolder
    case unsupportedMountPath(String)
    case driveMissing
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSiteURL:
            String(localized: "站点地址无效")
        case .serverTooOld(let version):
            String(localized: "服务器版本过低（\(version)），需要 ≥ \(OAuthConstants.minimumServerVersion)")
        case .unrecognizedVersion(let version):
            String(localized: "无法识别的服务器版本：\(version)")
        case .notAFolder:
            String(localized: "挂载路径不是目录")
        case .unsupportedMountPath(let path):
            String(localized: "不支持的挂载路径：\(path)")
        case .driveMissing:
            String(localized: "要重新登录的云盘已不存在")
        case .accountMismatch:
            String(localized: "登录的账号与该云盘原账号不一致")
        }
    }
}
