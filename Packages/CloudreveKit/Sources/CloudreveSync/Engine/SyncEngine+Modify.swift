import CloudreveAPI
import Foundation

extension SyncEngine {
    /// 依次应用 文件名 → 父目录 → 内容。某步失败时，若之前已有步骤成功则返回剩余字段让系统稍后重试，
    /// 否则抛错。日期、扩展属性、标签等字段不同步，视为已应用。
    public func modify(
        id: String, fields: ItemFields, newName: String?, newParentID: String?, contents: URL?, mtime: Date?,
        baseContentVersion: String?, failOnConflict: Bool, progress: @escaping ProgressHandler
    ) async throws -> ModifyResult {
        try await run {
            var current = try self.localItem(id: id)
            var pending = fields.intersection(.synced)
            var appliedAny = false
            do {
                if pending.contains(.filename), let newName, newName != current.name {
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
                        baseContentVersion: baseContentVersion, failOnConflict: failOnConflict, progress: progress
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

    /// 以新版本覆盖内容；`previous` 乐观锁冲突时按 `failOnConflict` 抛错或另存冲突副本。
    private func replaceContents(
        of item: SyncItem, contents: URL?, mtime: Date, baseContentVersion: String?, failOnConflict: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> ModifyResult {
        guard let parentID = item.parentID else { throw SyncError.cannotSynchronize("不能修改云盘根目录内容") }
        let previous = baseContentVersion.flatMap { $0.isEmpty ? nil : $0 }
        let transfer = try makeTransfer(uri: item.uri, itemID: item.id, contents: contents)
        do {
            let file = try await upload(contents: contents, to: item.uri, mtime: mtime, overwrite: .version(previous: previous),
                                        transfer: transfer, progress: progress)
            transfer.finish(error: nil)
            return ModifyResult(item: try store(file, parentID: parentID, uri: item.uri), pendingFields: [], shouldFetchContent: false)
        } catch let error as CloudreveAPIError where [40076, 40004].contains(error.serverCode ?? 0) {
            guard !failOnConflict else {
                transfer.finish(error: Self.describe(SyncError.versionConflict))
                throw SyncError.versionConflict
            }
            return try await saveConflictCopy(of: item, parentID: parentID, contents: contents, mtime: mtime,
                                              transfer: transfer, progress: progress)
        } catch {
            transfer.finish(error: Self.describe(error))
            throw error
        }
    }

    /// 把本地内容另存为同目录下的冲突副本，原条目回到服务端版本（系统随后重新下载）。
    private func saveConflictCopy(
        of item: SyncItem, parentID: String, contents: URL?, mtime: Date, transfer: TransferProgress,
        progress: @escaping ProgressHandler
    ) async throws -> ModifyResult {
        let copyName = ConflictNaming.conflictCopyName(for: item.name, at: now())
        guard let parentURI = item.uri.parent else { throw SyncError.cannotSynchronize("冲突副本缺少父目录") }
        let copyURI = parentURI.appending(copyName)
        let copyTransfer = try makeTransfer(uri: copyURI, itemID: nil, contents: contents)
        do {
            let copy = try await upload(contents: contents, to: copyURI, mtime: mtime, overwrite: .create,
                                        transfer: copyTransfer, progress: progress)
            copyTransfer.finish(error: nil)
            try store(copy, parentID: parentID, uri: copyURI)
        } catch {
            copyTransfer.finish(error: Self.describe(error))
            transfer.finish(error: "版本冲突，另存副本失败：\(Self.describe(error))")
            throw error
        }
        transfer.finish(error: "版本冲突，已另存为 \(copyName)")
        Log.shared.info("engine", "内容冲突：\(item.uri) 本地版本已另存为 \(copyName)")
        let server = try await client.fileInfo(uri: item.uri)
        let current = try store(server, parentID: parentID, uri: item.uri)
        return ModifyResult(item: current, pendingFields: [], shouldFetchContent: true)
    }
}
