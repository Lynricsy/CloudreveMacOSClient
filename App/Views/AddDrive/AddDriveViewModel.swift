import AppKit
import CloudreveAPI
import CloudreveSync
import Foundation
import Observation

/// 添加云盘 / 重新登录流程（与 Windows 版 `url_input → waiting → setting_up → success` 对齐）。
@MainActor
@Observable
final class AddDriveViewModel {
    private(set) var step: AddDriveStep = .enterURL
    var siteURLText = ""
    private(set) var siteTitle: String?
    /// 非 nil 表示重新登录该云盘：站点固定，成功后只更新凭证与状态。
    let reauthorizeDriveID: String?

    @ObservationIgnored private let driveManager: DriveManager
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    init(request: AddDriveRequest, driveManager: DriveManager) {
        self.driveManager = driveManager
        reauthorizeDriveID = request.reauthorizeDriveID
        if let id = request.reauthorizeDriveID, let drive = driveManager.drive(id: id) {
            siteURLText = drive.siteURL.absoluteString
            siteTitle = drive.siteTitle
        }
    }

    var isReauthorizing: Bool { reauthorizeDriveID != nil }

    var canStart: Bool {
        !siteURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && flowTask == nil
    }

    /// 开始流程；`anchor` 为授权窗口的宿主窗口。
    func start(anchor: NSWindow?) {
        guard flowTask == nil else { return }
        flowTask = Task { [weak self] in
            await self?.run(anchor: anchor)
            self?.flowTask = nil
        }
    }

    /// 取消进行中的授权（关闭浏览器会话），回到地址输入。
    func cancel() {
        flowTask?.cancel()
    }

    func retry() {
        step = .enterURL
    }

    private func run(anchor: NSWindow?) async {
        do {
            let site = try Self.normalizedSite(siteURLText)
            step = .checking
            let title = try await checkServer(site)
            siteTitle = title ?? siteTitle
            step = .authorizing
            let pkce = try PKCE()
            let callback = try await OAuthFlow.shared.authorize(site: site, pkce: pkce, state: makeState(), anchor: anchor)
            step = .settingUp
            let oauth = try await CloudreveClient.exchangeOAuthCode(
                site: site, transport: DriveRuntime.transport, code: callback.code, codeVerifier: pkce.verifier
            )
            let credentials = try Credentials(oauth: oauth, now: Date())
            if let reauthorizeDriveID {
                try await reauthorize(driveID: reauthorizeDriveID, callback: callback, credentials: credentials)
                step = .success(driveID: reauthorizeDriveID)
            } else {
                let driveID = try await addNewDrive(site: site, callback: callback, credentials: credentials)
                step = .success(driveID: driveID)
            }
        } catch OAuthError.cancelled {
            step = .enterURL
        } catch is CancellationError {
            step = .enterURL
        } catch {
            step = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// ping 校验版本 ≥ 4.12.0，并取站点标题（标题获取失败不影响流程）。
    private func checkServer(_ site: URL) async throws -> String? {
        let client = CloudreveClient(site: site, transport: DriveRuntime.transport, tokens: nil, clientID: nil)
        let versionText = try await client.ping()
        guard let version = ServerVersion.parse(versionText) else { throw AddDriveError.unrecognizedVersion(versionText) }
        guard version.isSupported else { throw AddDriveError.serverTooOld(versionText) }
        let config = try? await client.siteBasicConfig()
        return config?.title.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 重新授权的 state 以 `reauthorize:` 开头，服务端据此跳过挂载目录选择。
    private func makeState() -> String {
        guard let reauthorizeDriveID else { return UUID().uuidString }
        return "\(OAuthConstants.reauthorizePrefix)\(reauthorizeDriveID):\(UUID().uuidString)"
    }

    /// 新云盘：凭证入钥匙串 → 校验账号与挂载目录 → 写库并注册域。任一步失败都删除钥匙串条目，不留孤立凭证。
    private func addNewDrive(site: URL, callback: OAuthCallback, credentials: Credentials) async throws -> String {
        let driveID = UUID().uuidString
        let clientID = UUID()
        let rootURI = try Self.mountURI(callback.path)
        let keychain = KeychainCredentialStore()
        try keychain.save(credentials, driveID: driveID)
        do {
            let client = DriveRuntime.makeClient(driveID: driveID, site: site, clientID: clientID)
            let user = try await client.me()
            let root = try await client.fileInfo(uri: rootURI)
            guard root.isFolder else { throw AddDriveError.notAFolder }
            let capacity = try await client.capacity()
            let setup = DriveSetup(
                driveID: driveID, clientID: clientID, site: site, rootURI: rootURI, root: root,
                name: callback.name ?? siteTitle ?? site.host() ?? "Cloudreve",
                userID: callback.userID.isEmpty ? user.id : callback.userID, user: user, siteTitle: siteTitle, capacity: capacity
            )
            try await driveManager.addDrive(setup)
        } catch {
            try? keychain.delete(driveID: driveID)
            throw error
        }
        await NotificationService.requestAuthorization()
        return driveID
    }

    /// 重新登录：替换凭证并确认仍是同一账号；失败时恢复原凭证。
    private func reauthorize(driveID: String, callback: OAuthCallback, credentials: Credentials) async throws {
        guard let drive = try driveManager.driveStore.get(id: driveID) else { throw AddDriveError.driveMissing }
        let keychain = KeychainCredentialStore()
        let previous = try? keychain.load(driveID: driveID)
        try keychain.save(credentials, driveID: driveID)
        do {
            let user = try await DriveRuntime.makeClient(drive: drive).me()
            guard drive.userID == user.id || drive.userID == callback.userID else { throw AddDriveError.accountMismatch }
        } catch {
            if let previous {
                try? keychain.save(previous, driveID: driveID)
            } else {
                try? keychain.delete(driveID: driveID)
            }
            throw error
        }
        try await driveManager.completeReauthorization(driveID: driveID)
    }

    /// 补全 scheme（默认 https）、去掉末尾 `/`，只接受带主机名的 http(s) 地址。
    static func normalizedSite(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else {
            throw AddDriveError.invalidSiteURL
        }
        return url
    }

    /// 网页挂载设置返回的目录：空 → 用户根目录；`cloudreve://my/...` 原样解析；`/a/b` 视为 my 下路径。
    static func mountURI(_ path: String?) throws -> CloudreveURI {
        guard let path, !path.isEmpty else { return .my("") }
        if let uri = CloudreveURI(string: path) { return uri }
        if path.hasPrefix("/") { return .my(path) }
        throw AddDriveError.unsupportedMountPath(path)
    }
}
