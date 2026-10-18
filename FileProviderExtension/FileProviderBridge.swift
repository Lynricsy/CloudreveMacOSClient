import CloudreveAPI
import CloudreveSync
import FileProvider
import Foundation

/// NSFileProvider 类型 ↔ CloudreveSync 值类型的转换。不包含任何同步决策。
enum FileProviderBridge {
    // MARK: - 标识符

    /// 系统标识符 → 引擎 id（根容器 → 挂载根的远端 id）。
    static func syncID(_ identifier: NSFileProviderItemIdentifier, rootID: String) -> String {
        identifier == .rootContainer ? rootID : identifier.rawValue
    }

    /// 引擎 id → 系统标识符（挂载根 → `.rootContainer`）。
    static func identifier(_ id: String?, rootID: String) -> NSFileProviderItemIdentifier {
        guard let id, id != rootID else { return .rootContainer }
        return NSFileProviderItemIdentifier(id)
    }

    // MARK: - 字段

    private static let fieldPairs: [(NSFileProviderItemFields, ItemFields)] = [
        (.filename, .filename),
        (.contents, .contents),
        (.parentItemIdentifier, .parent),
        (.contentModificationDate, .contentModificationDate),
        (.creationDate, .creationDate),
        (.lastUsedDate, .lastUsedDate),
        (.extendedAttributes, .extendedAttributes),
        (.fileSystemFlags, .fileSystemFlags),
        (.tagData, .tagData),
        (.favoriteRank, .favoriteRank),
        (.typeAndCreator, .typeAndCreator)
    ]

    static func fields(_ fields: NSFileProviderItemFields) -> ItemFields {
        fieldPairs.reduce(into: ItemFields()) { result, pair in
            if fields.contains(pair.0) { result.insert(pair.1) }
        }
    }

    static func fields(_ fields: ItemFields) -> NSFileProviderItemFields {
        fieldPairs.reduce(into: NSFileProviderItemFields()) { result, pair in
            if fields.contains(pair.1) { result.insert(pair.0) }
        }
    }

    // MARK: - 版本

    /// 系统版本 → 引擎内容版本（entityID）。`beforeFirstSyncComponent` 表示系统从未确认过与服务端同步的版本，
    /// 不是真实 entityID，返回 nil（引擎据此改用镜像记录做乐观锁）。
    static func contentVersion(_ version: NSFileProviderItemVersion?) -> String? {
        guard let data = version?.contentVersion, !data.isEmpty,
              data != NSFileProviderItemVersion.beforeFirstSyncComponent else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 错误

    /// 引擎错误 → 系统错误（只允许 NSCocoaErrorDomain / NSFileProviderErrorDomain）。
    ///
    /// 只有 SyncError 才映射为 NSFileProviderError；其余错误（钥匙串、本地文件、网络栈等）不能一律当成
    /// `.cannotSynchronize`——系统收到它后不再自动重试 create/modify。按 SDK 约定：Cocoa 域原样返回，
    /// 其他域包成 `NSXPCConnectionReplyInvalid` 并附带原错误，系统视为暂时性错误并重试。
    static func nsError(_ error: any Error, rootID: String) -> NSError {
        if error is CancellationError {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }
        if let syncError = error as? SyncError {
            return nsError(syncError, rootID: rootID)
        }
        if error is CloudreveAPIError {
            let mapped = SyncErrorMapper.map(error)
            if let syncError = mapped as? SyncError { return nsError(syncError, rootID: rootID) }
            return wrapped(mapped as NSError)
        }
        return wrapped(error as NSError)
    }

    private static func nsError(_ error: SyncError, rootID: String) -> NSError {
        switch error {
        case .filenameCollision(existing: let existing?):
            // SDK 要求带上已存在的条目，系统据此改名其中一方后重试
            return NSError.fileProviderErrorForCollision(with: FileProviderItem(existing, rootID: rootID))
        case .deletionRejected(latest: let latest?):
            // 带上服务端最新条目，系统据此恢复被删的本地文件
            return NSError.fileProviderErrorForRejectedDeletion(of: FileProviderItem(latest, rootID: rootID))
        default:
            // 附带中文描述，便于在 Finder 与日志中查看原因
            let userInfo = [NSLocalizedDescriptionKey: error.localizedDescription]
            return NSFileProviderError(code(for: error), userInfo: userInfo) as NSError
        }
    }

    private static func wrapped(_ error: NSError) -> NSError {
        if error.domain == NSCocoaErrorDomain || error.domain == NSFileProviderErrorDomain { return error }
        let userInfo: [String: Any] = [NSUnderlyingErrorKey: error, NSLocalizedDescriptionKey: error.localizedDescription]
        return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid, userInfo: userInfo)
    }

    static func code(for error: SyncError) -> NSFileProviderError.Code {
        switch error {
        case .notAuthenticated: return .notAuthenticated
        case .serverUnreachable: return .serverUnreachable
        case .noSuchItem: return .noSuchItem
        case .filenameCollision: return .filenameCollision
        case .insufficientQuota: return .insufficientQuota
        case .syncAnchorExpired: return .syncAnchorExpired
        case .versionConflict: return .localVersionConflictingWithServer
        case .excludedFromSync: return .excludedFromSync
        case .directoryNotEmpty: return .directoryNotEmpty
        case .deletionRejected: return .deletionRejected
        case .cannotSynchronize: return .cannotSynchronize
        // fetchContents 的错误中只有未认证、服务器不可达会让系统退避到下次通知；其他错误一律视为暂时性并立即重下
        // （NSFileProviderReplicatedExtension.h）。摘要不符多半是服务端存储损坏，重下只会反复下载整个文件。
        // 服务端修复或产生新版本时会有远端事件，App 随即通知系统重试
        case .integrityCheckFailed: return .serverUnreachable
        }
    }

    /// 扩展初始化失败（数据库或云盘记录不可用）时返回给系统的错误。
    static func unavailable(_ reason: String) -> NSError {
        NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: reason]) as NSError
    }
}
