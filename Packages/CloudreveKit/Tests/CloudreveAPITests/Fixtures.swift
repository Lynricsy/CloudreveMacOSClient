import Foundation
@testable import CloudreveAPI

enum Fixtures {
    static let site = URL(string: "https://drive.example.com/")!
    static let driveID = "drive-1"

    static func credentials(access: String = "old-access", accessIn: TimeInterval = 3600, refreshIn: TimeInterval = 86400) -> Credentials {
        Credentials(
            accessToken: access,
            refreshToken: "refresh-\(access)",
            accessExpires: Date().addingTimeInterval(accessIn),
            refreshExpires: Date().addingTimeInterval(refreshIn)
        )
    }

    static func refreshJSON(access: String) -> String {
        let soon = CloudreveDate.format(Date().addingTimeInterval(3600))
        let later = CloudreveDate.format(Date().addingTimeInterval(86400))
        return #"{"access_token":"\#(access)","refresh_token":"r-\#(access)","access_expires":"\#(soon)","refresh_expires":"\#(later)"}"#
    }

    /// 带 TokenManager 的客户端，刷新走同一个 MockTransport。
    static func client(mock: MockTransport, store: InMemoryCredentialStore) -> CloudreveClient {
        let tokens = TokenManager(driveID: driveID, store: store) { refreshToken in
            try await CloudreveClient.refresh(site: site, transport: mock, refreshToken: refreshToken)
        }
        return CloudreveClient(site: site, transport: mock, tokens: tokens, clientID: UUID())
    }
}
