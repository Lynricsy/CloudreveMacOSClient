import CloudreveSync
import FileProvider

/// 基于变更日志（sync anchor = change_log.seq）的变更枚举，供所有枚举器共用。
enum ChangeEnumeration {
    /// SDK 把初始页常量暴露为 `NSData`，需按原始字节比较。
    static func isInitial(_ page: NSFileProviderPage) -> Bool {
        let raw = page.rawValue
        return raw == NSFileProviderPage.initialPageSortedByName as Data
            || raw == NSFileProviderPage.initialPageSortedByDate as Data
    }

    static func enumerateChanges(runtime: ExtensionRuntime, observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let box = SendableBox(observer)
        guard let since = SyncAnchorCodec.decode(anchor.rawValue) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        Task {
            do {
                // 在系统请求内应用 App 落库的远端变更：请求未完成前扩展不会被回收。
                // 失败直接报错（队列保留），由系统按错误类型重试或提示（如需要重新登录）。
                _ = try await runtime.engine.applyQueuedRemoteChanges()
                let batch = try await runtime.engine.changes(since: since)
                if !batch.updated.isEmpty {
                    box.value.didUpdate(batch.updated.map(runtime.item))
                }
                if !batch.deleted.isEmpty {
                    let identifiers = batch.deleted.map { FileProviderBridge.identifier($0, rootID: runtime.rootID) }
                    box.value.didDeleteItems(withIdentifiers: identifiers)
                }
                let next = NSFileProviderSyncAnchor(rawValue: SyncAnchorCodec.encode(batch.anchor))
                box.value.finishEnumeratingChanges(upTo: next, moreComing: batch.moreComing)
            } catch {
                box.value.finishEnumeratingWithError(FileProviderBridge.nsError(error))
            }
        }
    }

    static func currentSyncAnchor(runtime: ExtensionRuntime, completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let reply = SendableBox(completionHandler)
        Task {
            let seq = (try? await runtime.engine.currentAnchor()) ?? 0
            reply.value(NSFileProviderSyncAnchor(rawValue: SyncAnchorCodec.encode(seq)))
        }
    }
}
