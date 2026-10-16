import CloudreveAPI
import CloudreveSync
import Foundation

/// App 与扩展共用的客户端装配：URLSession 传输 + 共享 Keychain 凭证 + 云盘 clientID。
enum DriveRuntime {
    /// 进程内共享一个传输实例（复用连接）。
    static let transport = URLSessionTransport(
        userAgentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    )

    static func makeClient(drive: DriveRecord) -> CloudreveClient {
        makeClient(driveID: drive.id, site: drive.siteURL, clientID: drive.clientID)
    }

    static func makeClient(driveID: String, site: URL, clientID: UUID) -> CloudreveClient {
        let transport = Self.transport
        let tokens = TokenManager(driveID: driveID, store: KeychainCredentialStore()) { refreshToken in
            try await CloudreveClient.refresh(site: site, transport: transport, refreshToken: refreshToken)
        }
        return CloudreveClient(site: site, transport: transport, tokens: tokens, clientID: clientID)
    }
}
