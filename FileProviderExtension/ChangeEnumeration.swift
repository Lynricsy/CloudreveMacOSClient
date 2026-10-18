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

    /// working set：上报全域变更。
    static func enumerateChanges(runtime: ExtensionRuntime, observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        enumerate(runtime: runtime, observer: observer, from: anchor) { box, batch in
            if !batch.updated.isEmpty {
                box.value.didUpdate(batch.updated.map(runtime.item))
            }
            if !batch.deleted.isEmpty {
                let identifiers = batch.deleted.map { FileProviderBridge.identifier($0, rootID: runtime.rootID) }
                box.value.didDeleteItems(withIdentifiers: identifiers)
            }
            let next = NSFileProviderSyncAnchor(rawValue: SyncAnchorCodec.encode(batch.anchor))
            box.value.finishEnumeratingChanges(upTo: next, moreComing: batch.moreComing)
        }
    }

    /// 普通目录 / 单个文档的变更枚举。变更日志是全域的：
    /// - 文档：只上报该文档自身的更新，其他条目的变化不影响它；
    /// - 目录：SDK 要求只上报该容器内的变化，而全域日志无法可靠还原移入、移出与删除的作用域，
    ///   因此 anchor 之后只要有任何变更就让 anchor 过期，由系统重新枚举该目录；
    /// - 本地镜像已没有该条目（已删除，无从判断类型）：有变更时同样过期，重新枚举时得到 `.noSuchItem`。
    /// 没有变更时正常结束。
    static func enumerateScopedChanges(
        runtime: ExtensionRuntime, id: String, observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        enumerate(runtime: runtime, observer: observer, from: anchor) { box, batch in
            let next = NSFileProviderSyncAnchor(rawValue: SyncAnchorCodec.encode(batch.anchor))
            if let item = try? await runtime.engine.item(id: id), !item.isFolder {
                if batch.updated.contains(where: { $0.id == id }) {
                    box.value.didUpdate([runtime.item(item)])
                }
                box.value.finishEnumeratingChanges(upTo: next, moreComing: batch.moreComing)
                return
            }
            guard batch.updated.isEmpty, batch.deleted.isEmpty, !batch.moreComing else {
                box.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            box.value.finishEnumeratingChanges(upTo: next, moreComing: false)
        }
    }

    private static func enumerate(
        runtime: ExtensionRuntime, observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor,
        report: @escaping @Sendable (SendableBox<any NSFileProviderChangeObserver>, ChangeBatch) async -> Void
    ) {
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
                await report(box, batch)
            } catch {
                box.value.finishEnumeratingWithError(runtime.nsError(error))
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
