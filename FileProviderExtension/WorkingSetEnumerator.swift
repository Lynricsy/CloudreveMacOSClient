import CloudreveSync
import FileProvider

/// working set 枚举：全部已知条目按 rowid 分页；变更来自变更日志。
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let runtime: ExtensionRuntime

    static let pageSize = 500

    init(runtime: ExtensionRuntime) {
        self.runtime = runtime
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let box = SendableBox(observer)
        let afterRowID = ChangeEnumeration.isInitial(page) ? 0 : (SyncAnchorCodec.decode(page.rawValue) ?? 0)
        let runtime = runtime
        Task {
            do {
                let (items, next) = try await runtime.engine.workingSetItems(afterRowID: afterRowID, limit: WorkingSetEnumerator.pageSize)
                box.value.didEnumerate(items.map(runtime.item))
                box.value.finishEnumerating(upTo: next.map { NSFileProviderPage(rawValue: SyncAnchorCodec.encode($0)) })
            } catch {
                box.value.finishEnumeratingWithError(FileProviderBridge.nsError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        ChangeEnumeration.enumerateChanges(runtime: runtime, observer: observer, from: anchor)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        ChangeEnumeration.currentSyncAnchor(runtime: runtime, completionHandler: completionHandler)
    }
}
