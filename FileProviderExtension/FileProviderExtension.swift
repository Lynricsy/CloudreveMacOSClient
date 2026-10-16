import CloudreveAPI
import CloudreveSync
import FileProvider
import UniformTypeIdentifiers

/// File Provider 扩展入口：每个云盘域一个实例。只做系统类型与引擎之间的桥接。
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let runtime: ExtensionRuntime?
    private let initError: String?

    required init(domain: NSFileProviderDomain) {
        do {
            let runtime = try ExtensionRuntime.make(domain: domain)
            self.runtime = runtime
            initError = nil
            Task {
                try? await runtime.engine.maintenance()
                await runtime.listener.start()
            }
        } catch {
            runtime = nil
            initError = error.localizedDescription
            Log.shared.error("extension", "域 \(domain.identifier.rawValue) 初始化失败：\(error)")
        }
        super.init()
    }

    func invalidate() {
        guard let listener = runtime?.listener else { return }
        Task { await listener.stop() }
    }

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let reply = SendableBox(completionHandler)
        let rawID = identifier.rawValue
        return launch(onError: { reply.value(nil, $0) }, body: { runtime in
            let item = try await runtime.engine.item(id: runtime.syncID(raw: rawID))
            reply.value(runtime.item(item), nil)
        })
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let reply = SendableBox(completionHandler)
        let rawID = itemIdentifier.rawValue
        let version = FileProviderBridge.contentVersion(requestedVersion)
        let progress = Progress(totalUnitCount: 100)
        let tracker = SendableBox(progress)
        return launch(progress: progress, onError: { reply.value(nil, nil, $0) }, body: { runtime in
            let url = try runtime.manager.value.temporaryDirectoryURL().appending(path: UUID().uuidString)
            let item = try await runtime.engine.download(id: runtime.syncID(raw: rawID), version: version, to: url) { done, total in
                tracker.value.totalUnitCount = max(total, 1)
                tracker.value.completedUnitCount = done
            }
            reply.value(url, runtime.item(item), nil)
        })
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let reply = SendableBox(completionHandler)
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier.rawValue
        let type = itemTemplate.contentType ?? .data
        let mtime = itemTemplate.contentModificationDate.flatMap { $0 } ?? Date()
        let mayExist = options.contains(.mayAlreadyExist)
        // 符号链接、替身与软件包（.app/.rtfd 等目录包）不同步，保留在本地
        if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) || type.conforms(to: .package) {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return Progress(totalUnitCount: 1)
        }
        return launch(onError: { reply.value(nil, [], false, $0) }, body: { runtime in
            let parentID = runtime.syncID(raw: parent)
            let created: SyncItem
            if type.conforms(to: .folder) {
                created = try await runtime.engine.createFolder(name: name, parentID: parentID, mayAlreadyExist: mayExist)
            } else {
                created = try await runtime.engine.createFile(
                    name: name, parentID: parentID, contents: url, mtime: mtime, mayAlreadyExist: mayExist, progress: { _, _ in }
                )
            }
            reply.value(runtime.item(created), [], false, nil)
        })
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
        contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let reply = SendableBox(completionHandler)
        let identifier = item.itemIdentifier.rawValue
        let name = item.filename
        let parent = item.parentItemIdentifier.rawValue
        let mtime = item.contentModificationDate.flatMap { $0 }
        let base = FileProviderBridge.contentVersion(version)
        let fields = FileProviderBridge.fields(changedFields)
        let failOnConflict = options.contains(.failOnConflict)
        return launch(onError: { reply.value(nil, [], false, $0) }, body: { runtime in
            let result = try await runtime.engine.modify(
                id: runtime.syncID(raw: identifier), fields: fields, newName: name, newParentID: runtime.syncID(raw: parent),
                contents: newContents, mtime: mtime, baseContentVersion: base, failOnConflict: failOnConflict, progress: { _, _ in }
            )
            reply.value(runtime.item(result.item), FileProviderBridge.fields(result.pendingFields), result.shouldFetchContent, nil)
        })
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let reply = SendableBox(completionHandler)
        let rawID = identifier.rawValue
        let recursive = options.contains(.recursive)
        return launch(onError: { reply.value($0) }, body: { runtime in
            try await runtime.engine.delete(id: runtime.syncID(raw: rawID), recursive: recursive)
            reply.value(nil)
        })
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard let runtime else { throw FileProviderBridge.unavailable(initError ?? "扩展未初始化") }
        switch containerItemIdentifier {
        case .workingSet:
            return WorkingSetEnumerator(runtime: runtime)
        case .trashContainer:
            throw NSFileProviderError(.noSuchItem)
        default:
            return FolderEnumerator(runtime: runtime, folderID: runtime.syncID(raw: containerItemIdentifier.rawValue))
        }
    }

    /// 桥接模板：在 Task 中执行异步操作，失败统一映射为 NSFileProviderError；取消 Progress 即取消 Task。
    func launch(
        progress: Progress = Progress(totalUnitCount: 1),
        onError: @escaping @Sendable (NSError) -> Void,
        body: @escaping @Sendable (ExtensionRuntime) async throws -> Void
    ) -> Progress {
        guard let runtime else {
            onError(FileProviderBridge.unavailable(initError ?? "扩展未初始化"))
            return progress
        }
        let task = Task {
            do {
                try await body(runtime)
            } catch {
                onError(FileProviderBridge.nsError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
