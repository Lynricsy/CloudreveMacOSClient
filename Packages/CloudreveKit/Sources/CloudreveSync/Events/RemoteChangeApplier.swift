import CloudreveAPI
import Foundation

/// 监听器收到推送后的处理方（便于测试替换）。
public protocol RemoteChangeApplier: Sendable {
    /// 需要全量兜底，返回是否需要通知扩展。
    func reconcile() async throws -> Bool
    /// 收到推送事件，返回是否需要通知扩展。
    func applyRemoteEvents(_ events: [FileEvent]) async throws -> Bool
}

/// 把推送写入 `remote_event` 队列，由扩展在系统请求内经 `SyncEngine.applyQueuedRemoteChanges()` 应用。
/// 写入即返回 true：是否真有变化由扩展应用后判断。
public struct QueueingRemoteChangeApplier: RemoteChangeApplier {
    private let queue: RemoteEventQueue
    private let driveID: String

    public init(queue: RemoteEventQueue, driveID: String) {
        self.queue = queue
        self.driveID = driveID
    }

    public func reconcile() async throws -> Bool {
        try queue.requestReconcile(driveID: driveID)
        return true
    }

    public func applyRemoteEvents(_ events: [FileEvent]) async throws -> Bool {
        try queue.append(driveID: driveID, events: events)
        return true
    }
}
