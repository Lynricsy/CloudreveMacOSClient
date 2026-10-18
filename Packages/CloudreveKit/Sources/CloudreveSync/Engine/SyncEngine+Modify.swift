import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 依次应用 文件名 → 父目录 → 内容。某步失败时，若之前已有步骤成功则返回剩余字段让系统稍后重试，
    /// 否则抛错。日期、扩展属性、标签等字段不同步，视为已应用。
    ///
    /// 内容以乐观锁覆盖：`baseContentVersion` 为 nil 表示系统未提供可靠版本，此时以镜像记录的 entity 为锁；
    /// 镜像也没有 entity 时先查服务端，服务端已有内容则按冲突处理，不得无锁覆盖。
    public func modify(
        id: String, fields: ItemFields, newName: String?, newParentID: String?, contents: URL?, mtime: Date?,
        baseContentVersion: String?, failOnConflict: Bool, progress: @escaping ProgressHandler
    ) async throws -> ModifyResult {
        try await run {
            var current = try self.localItem(id: id)
            // 重命名/移动会用服务端返回值刷新 entity，锁必须取修改前镜像中的版本
            let lock = Self.nonEmpty(baseContentVersion) ?? Self.nonEmpty(current.entityID)
            var pending = fields.intersection(.synced)
            var appliedAny = false
            do {
                if pending.contains(.filename), let newName, !Self.sameScalars(Self.normalizedName(newName), current.name) {
                    current = try await self.renameItem(id: id, newName: newName)
                    appliedAny = true
                }
                pending.remove(.filename)
                if pending.contains(.parent), let newParentID, newParentID != current.parentID {
                    current = try await self.moveItem(id: id, toParentID: newParentID)
                    appliedAny = true
                }
                pending.remove(.parent)
                if pending.contains(.contents), !current.isFolder {
                    let result = try await self.replaceContents(
                        of: current, contents: contents, mtime: mtime ?? self.now(),
                        lock: lock, failOnConflict: failOnConflict, progress: progress
                    )
                    if result.shouldFetchContent { return result }
                    current = result.item
                }
                pending.remove(.contents)
                return ModifyResult(item: current, pendingFields: [], shouldFetchContent: false)
            } catch {
                guard appliedAny, !(error is CancellationError) else { throw error }
                Log.shared.info("engine", "部分字段已应用，剩余字段稍后重试：\(error)")
                return ModifyResult(item: current, pendingFields: pending, shouldFetchContent: false)
            }
        }
    }

    /// 以新版本覆盖内容；`lock` 乐观锁冲突时按 `failOnConflict` 抛错或另存冲突副本。
    private func replaceContents(
        of item: SyncItem, contents: URL?, mtime: Date, lock: String?, failOnConflict: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> ModifyResult {
        guard item.parentID != nil else { throw SyncError.cannotSynchronize("不能修改云盘根目录内容") }
        // 镜像路径可能已过期（远端改名/移动后原路径被另一个文件占用）：按 id 解析当前位置再覆盖
        let location = try await currentLocation(of: try localRecord(id: item.id))
        let transfer = try makeTransfer(uri: location.uri, itemID: item.id, contents: contents)
        do {
            // 无锁时只在服务端尚无内容才覆盖；检查与上传之间仍有极短窗口，服务端没有可加锁的版本，无法消除
            if lock == nil, Self.nonEmpty(location.file.primaryEntity) != nil { throw SyncError.versionConflict }
            let file = try await upload(contents: contents, to: location.uri, mtime: mtime, overwrite: .version(previous: lock),
                                        transfer: transfer, progress: progress)
            transfer.finish(error: nil)
            let stored = try store(file, parentID: location.parentID, uri: location.uri)
            return ModifyResult(item: stored, pendingFields: [], shouldFetchContent: false)
        } catch where Self.isVersionConflict(error) {
            guard !failOnConflict else {
                transfer.finish(error: Self.describe(SyncError.versionConflict), isConflict: true)
                throw SyncError.versionConflict
            }
            return try await saveConflictCopy(at: location, contents: contents, mtime: mtime, transfer: transfer, progress: progress)
        } catch {
            transfer.finish(error: Self.describe(error))
            throw error
        }
    }

    private static func isVersionConflict(_ error: any Error) -> Bool {
        if let apiError = error as? CloudreveAPIError { return [40076, 40004].contains(apiError.serverCode ?? 0) }
        return error as? SyncError == .versionConflict
    }

    /// 把本地内容另存为同目录下的冲突副本，原条目回到服务端版本（系统随后重新下载）。
    private func saveConflictCopy(
        at location: RemoteLocation, contents: URL?, mtime: Date, transfer: TransferProgress,
        progress: @escaping ProgressHandler
    ) async throws -> ModifyResult {
        let copyName = ConflictNaming.conflictCopyName(for: location.file.name, at: now())
        let copyURI = location.parentURI.appending(copyName)
        let copyTransfer = try makeTransfer(uri: copyURI, itemID: nil, contents: contents)
        do {
            let copy = try await upload(contents: contents, to: copyURI, mtime: mtime, overwrite: .create,
                                        transfer: copyTransfer, progress: progress)
            copyTransfer.finish(error: nil)
            try store(copy, parentID: location.parentID, uri: copyURI)
        } catch {
            copyTransfer.finish(error: Self.describe(error))
            transfer.finish(error: "版本冲突，另存副本失败：\(Self.describe(error))", isConflict: true)
            throw error
        }
        transfer.finish(error: "版本冲突，已另存为 \(copyName)", isConflict: true)
        Log.shared.info("engine", "内容冲突：\(location.uri) 本地版本已另存为 \(copyName)")
        // 按 id 取回服务端当前版本（期间可能又被移动）
        guard let remote = try await remoteItem(id: location.file.id), let current = try await storeRemote(remote) else {
            throw SyncError.noSuchItem
        }
        return ModifyResult(item: current, pendingFields: [], shouldFetchContent: true)
    }
}
