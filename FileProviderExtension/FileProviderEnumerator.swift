import CloudreveSync
import FileProvider

/// 目录或单个文档的枚举器（系统请求时只给标识符，类型在枚举时按本地镜像判断）。
/// - 目录：按服务端游标分页；变更枚举只判断 anchor 之后有无变化，有则让系统重新枚举。
/// - 文档：只列出该文档本身；变更枚举只上报它自己的更新。
final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private let runtime: ExtensionRuntime
    private let itemID: String

    init(runtime: ExtensionRuntime, itemID: String) {
        self.runtime = runtime
        self.itemID = itemID
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let box = SendableBox(observer)
        let token = ChangeEnumeration.isInitial(page) ? nil : String(data: page.rawValue, encoding: .utf8)
        let runtime = runtime
        let itemID = itemID
        Task {
            do {
                let item = try await runtime.engine.item(id: itemID)
                guard item.isFolder else {
                    box.value.didEnumerate([runtime.item(item)])
                    box.value.finishEnumerating(upTo: nil)
                    return
                }
                let result = try await runtime.engine.enumerateFolder(id: itemID, pageToken: token)
                box.value.didEnumerate(result.items.map(runtime.item))
                box.value.finishEnumerating(upTo: result.nextToken.map { NSFileProviderPage(rawValue: Data($0.utf8)) })
            } catch {
                box.value.finishEnumeratingWithError(runtime.nsError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        ChangeEnumeration.enumerateScopedChanges(runtime: runtime, id: itemID, observer: observer, from: anchor)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        ChangeEnumeration.currentSyncAnchor(runtime: runtime, completionHandler: completionHandler)
    }
}
