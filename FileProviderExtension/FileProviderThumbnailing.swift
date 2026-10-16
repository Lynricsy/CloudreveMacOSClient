import CloudreveAPI
import CloudreveSync
import FileProvider

/// Finder 缩略图：向服务端取缩略图地址后下载字节，最多 4 个并发。
extension FileProviderExtension: NSFileProviderThumbnailing {
    static let thumbnailConcurrency = 4

    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let perItem = SendableBox(perThumbnailCompletionHandler)
        let done = SendableBox(completionHandler)
        let rawIDs = itemIdentifiers.map(\.rawValue)
        let progress = Progress(totalUnitCount: Int64(rawIDs.count))
        let tracker = SendableBox(progress)
        return launch(progress: progress, onError: { done.value($0) }, body: { runtime in
            await withTaskGroup(of: Void.self) { group in
                // 只在父任务里累加进度，避免子任务并发读改写 completedUnitCount 丢计数
                for (index, rawID) in rawIDs.enumerated() {
                    if index >= FileProviderExtension.thumbnailConcurrency, await group.next() != nil {
                        tracker.value.completedUnitCount += 1
                    }
                    group.addTask {
                        let identifier = NSFileProviderItemIdentifier(rawID)
                        do {
                            let data = try await FileProviderExtension.thumbnail(runtime: runtime, id: runtime.syncID(raw: rawID))
                            perItem.value(identifier, data, nil)
                        } catch {
                            perItem.value(identifier, nil, FileProviderBridge.nsError(error))
                        }
                    }
                }
                for await _ in group { tracker.value.completedUnitCount += 1 }
            }
            done.value(nil)
        })
    }

    /// 无缩略图时返回 nil。
    private static func thumbnail(runtime: ExtensionRuntime, id: String) async throws -> Data? {
        guard let url = try await runtime.engine.thumbnailURL(id: id) else { return nil }
        let (head, chunks) = try await runtime.client.fetch(url: url)
        guard (200..<300).contains(head.status) else { return nil }
        var data = Data()
        for try await chunk in chunks { data.append(chunk) }
        return data
    }
}
