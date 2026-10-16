import CloudreveSync
import FileProvider

/// 目录枚举：按服务端游标分页；变更枚举委托给全局变更日志。
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let runtime: ExtensionRuntime
    private let folderID: String

    init(runtime: ExtensionRuntime, folderID: String) {
        self.runtime = runtime
        self.folderID = folderID
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let box = SendableBox(observer)
        let token = ChangeEnumeration.isInitial(page) ? nil : String(data: page.rawValue, encoding: .utf8)
        let runtime = runtime
        let folderID = folderID
        Task {
            do {
                let result = try await runtime.engine.enumerateFolder(id: folderID, pageToken: token)
                box.value.didEnumerate(result.items.map(runtime.item))
                box.value.finishEnumerating(upTo: result.nextToken.map { NSFileProviderPage(rawValue: Data($0.utf8)) })
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
