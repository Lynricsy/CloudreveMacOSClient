import CloudreveSync
import FileProvider

/// 基于变更日志（sync anchor = change_log.seq）的变更枚举，供所有枚举器共用。
enum ChangeEnumeration {
    static func isInitial(_ page: NSFileProviderPage) -> Bool {
        page == NSFileProviderPage.initialPageSortedByName || page == NSFileProviderPage.initialPageSortedByDate
    }

    static func enumerateChanges(runtime: ExtensionRuntime, observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let box = SendableBox(observer)
        guard let since = SyncAnchorCodec.decode(anchor.rawValue) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        Task {
            do {
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
