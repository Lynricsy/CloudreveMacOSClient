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
            Task { try? await runtime.engine.maintenance() }
        } catch {
            runtime = nil
            initError = error.localizedDescription
            Log.shared.error("extension", "域 \(domain.identifier.rawValue) 初始化失败：\(error)")
        }
        super.init()
    }

    func invalidate() {}

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
        let track = Self.tracking(progress)
        return launch(progress: progress, onError: { reply.value(nil, nil, $0) }, body: { runtime in
            let url = try runtime.manager.value.temporaryDirectoryURL().appending(path: UUID().uuidString)
            let item = try await runtime.engine.download(id: runtime.syncID(raw: rawID), version: version, to: url, progress: track)
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
        let progress = Progress(totalUnitCount: 100)
        let track = Self.tracking(progress)
        return launch(progress: progress, onError: { reply.value(nil, [], false, $0) }, body: { runtime in
            let parentID = runtime.syncID(raw: parent)
            if type.conforms(to: .folder) {
                let created = try await runtime.engine.createFolder(name: name, parentID: parentID, mayAlreadyExist: mayExist)
                reply.value(runtime.item(created), [], false, nil)
                return
            }
            // 重新导入 dataless 文件（无内容）且服务端没有可匹配的条目时引擎返回 nil：按 SDK 回 nil item，
            // 系统随即删除本地占位，而不是在服务端凭空创建空文件。
            guard let created = try await runtime.engine.createFile(
                name: name, parentID: parentID, contents: url, mtime: mtime, mayAlreadyExist: mayExist, progress: track
            ) else {
                reply.value(nil, [], false, nil)
                return
            }
            // shouldFetchContent 恒为 false：引擎只在返回条目内容与 url 一致（已上传或服务端相同），
            // 或系统本就没有提供内容（本地是 dataless，按需再取）时返回条目；内容不同则抛 filenameCollision。
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
        let progress = Progress(totalUnitCount: 100)
        let track = Self.tracking(progress)
        return launch(progress: progress, onError: { reply.value(nil, [], false, $0) }, body: { runtime in
            let result = try await runtime.engine.modify(
                id: runtime.syncID(raw: identifier), fields: fields, newName: name, newParentID: runtime.syncID(raw: parent),
                contents: newContents, mtime: mtime, baseContentVersion: base, failOnConflict: failOnConflict, progress: track
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
        let base = FileProviderBridge.contentVersion(version)
        return launch(onError: { reply.value($0) }, body: { runtime in
            try await runtime.engine.delete(id: runtime.syncID(raw: rawID), recursive: recursive, baseContentVersion: base)
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
            return ItemEnumerator(runtime: runtime, itemID: runtime.syncID(raw: containerItemIdentifier.rawValue))
        }
    }

    /// 桥接模板：在 Task 中执行异步操作，失败经 `FileProviderBridge.nsError` 映射为系统错误；取消 Progress 即取消 Task。
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
                onError(runtime.nsError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// 引擎的字节进度 → 返回给系统的 Progress。上传进度必须持续推进，否则系统会取消「不再取得进展」的上传。
    static func tracking(_ progress: Progress) -> SyncEngine.ProgressHandler {
        let tracker = SendableBox(progress)
        return { done, total in
            tracker.value.totalUnitCount = max(total, 1)
            tracker.value.completedUnitCount = done
        }
    }
}
