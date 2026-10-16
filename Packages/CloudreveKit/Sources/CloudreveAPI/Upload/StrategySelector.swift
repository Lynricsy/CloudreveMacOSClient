import Foundation

/// 按上传会话的存储策略选择分片协议。
public enum StrategySelector {
    /// `fileSize` 供 OneDrive 的 `Content-Range` 使用。
    public static func strategy(for session: UploadSession, fileSize: Int64) throws -> any ChunkStrategy {
        let policy = session.storagePolicy
        let type = policy?.type ?? ""
        if policy?.relay == true || type == "local" { return LocalStrategy() }
        switch type {
        case "remote":
            let url = session.uploadURLs?.first ?? ""
            return !url.isEmpty && !url.hasPrefix("/") ? RemoteStrategy() : LocalStrategy()
        case "onedrive":
            return OneDriveStrategy(fileSize: fileSize)
        case "qiniu":
            return QiniuStrategy()
        case "upyun":
            return UpyunStrategy()
        default:
            guard let variant = S3FamilyStrategy.Variant(rawValue: type) else {
                throw CloudreveAPIError.server(code: -1, message: "unsupported policy type", correlationID: nil)
            }
            return S3FamilyStrategy(variant: variant)
        }
    }
}
