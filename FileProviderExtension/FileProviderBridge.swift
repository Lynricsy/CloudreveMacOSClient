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

    static func contentVersion(_ version: NSFileProviderItemVersion?) -> String? {
        guard let data = version?.contentVersion, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 错误

    /// 引擎错误 → NSFileProviderError；非 SyncError 先经 SyncErrorMapper。
    static func nsError(_ error: any Error) -> NSError {
        let mapped = SyncErrorMapper.map(error)
        if mapped is CancellationError {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }
        guard let syncError = mapped as? SyncError else {
            return NSFileProviderError(.cannotSynchronize) as NSError
        }
        // 附带中文描述，便于在 Finder 与日志中查看原因
        let userInfo = [NSLocalizedDescriptionKey: syncError.localizedDescription]
        return NSFileProviderError(code(for: syncError), userInfo: userInfo) as NSError
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
        case .cannotSynchronize: return .cannotSynchronize
        }
    }

    /// 扩展初始化失败（数据库或云盘记录不可用）时返回给系统的错误。
    static func unavailable(_ reason: String) -> NSError {
        NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: reason]) as NSError
    }
}
