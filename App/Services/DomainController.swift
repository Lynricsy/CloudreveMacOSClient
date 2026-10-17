import FileProvider
import Foundation

/// `NSFileProviderManager` 的薄封装：一个云盘 = 一个 File Provider 域，域 id 即 drive id。
/// 刻意不隔离到主 actor：域/管理器对象只在各函数内部使用，调用方只传入、取回 Sendable 值。
enum DomainController {
    /// 注册（或原地更新）云盘对应的域，Finder 侧栏随即出现该位置。
    static func add(driveID: String, name: String) async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: driveID), displayName: name)
        domain.supportsSyncingTrash = false
        try await NSFileProviderManager.add(domain)
    }

    /// 移除域及其全部本地副本；域不存在时视为已移除。
    static func remove(driveID: String) async throws {
        guard let domain = try await findDomain(driveID: driveID) else { return }
        _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
    }

    /// 通知系统重新枚举 working set（扩展随之拉取变更）。
    static func signalWorkingSet(driveID: String) async throws {
        try await manager(driveID: driveID).signalEnumerator(for: .workingSet)
    }

    static func reconnect(driveID: String) async throws {
        try await manager(driveID: driveID).reconnect()
    }

    /// 重新登录后解除系统对 `.notAuthenticated` 的节流。
    static func errorResolved(driveID: String) async throws {
        try await manager(driveID: driveID).signalErrorResolved(NSFileProviderError(.notAuthenticated))
    }

    /// 用户尚未在「系统设置 → 通用 → 登录项与扩展 → 文件提供程序」中启用的云盘。
    /// 新注册的域默认未启用，此时扩展不会被拉起，Finder 中访问云盘报错。
    static func disabledDriveIDs() async throws -> Set<String> {
        Set(try await NSFileProviderManager.domains().filter { !$0.userEnabled }.map(\.identifier.rawValue))
    }

    /// 条目在 Finder 中的路径；`item` 为 nil 时返回云盘根目录。
    static func userVisibleURL(driveID: String, item: String?) async throws -> URL {
        let identifier = item.map { NSFileProviderItemIdentifier(rawValue: $0) } ?? .rootContainer
        return try await manager(driveID: driveID).getUserVisibleURL(for: identifier)
    }

    private static func findDomain(driveID: String) async throws -> NSFileProviderDomain? {
        try await NSFileProviderManager.domains().first { $0.identifier.rawValue == driveID }
    }

    private static func manager(driveID: String) async throws -> NSFileProviderManager {
        guard let domain = try await findDomain(driveID: driveID),
              let manager = NSFileProviderManager(for: domain) else {
            throw DomainControllerError.domainNotFound(driveID)
        }
        return manager
    }
}
