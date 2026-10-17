import CloudreveAPI
import CloudreveSync
import Foundation

/// 远端变更门铃：常驻的 App 为每个云盘保持一条 SSE 订阅，把推送落入 `remote_event` 队列后唤醒 File Provider 扩展。
///
/// 扩展空闲几秒就会被系统回收，而服务端在投递前就删除离线事件，扩展自己订阅会丢事件。
/// 这里收到即落库（订阅成功或定期兜底时写入 reconcile 请求），再 `signalEnumerator(.workingSet)`；
/// 扩展在系统的变更枚举请求内应用队列、成功后删除。App 只写队列表，同步镜像仍由扩展独占写入。
///
/// 订阅复用云盘的 clientID（扩展不再订阅，不会争抢同一事件队列）：服务端不会把本机扩展自己的改动推回来，
/// App 重启后也以同一身份续订，不会在服务端遗留离线订阅者。
@MainActor
final class RemoteChangeDoorbell {
    private var listeners: [String: RemoteEventListener] = [:]

    /// 与当前云盘列表对齐：为新云盘开始订阅，停止已移除云盘的订阅。
    func sync(with drives: [DriveRecord], queue: RemoteEventQueue, driveStore: DriveStore) {
        let ids = Set(drives.map(\.id))
        for (id, listener) in listeners where !ids.contains(id) {
            Task { await listener.stop() }
            listeners[id] = nil
        }
        for drive in drives where listeners[drive.id] == nil {
            start(drive, queue: queue, driveStore: driveStore)
        }
    }

    /// 重新登录后重建订阅（凭证失效时监听器已自行停止）。
    func restart(_ drive: DriveRecord, queue: RemoteEventQueue, driveStore: DriveStore) {
        if let listener = listeners.removeValue(forKey: drive.id) {
            Task { await listener.stop() }
        }
        start(drive, queue: queue, driveStore: driveStore)
    }

    private func start(_ drive: DriveRecord, queue: RemoteEventQueue, driveStore: DriveStore) {
        let driveID = drive.id
        let listener = RemoteEventListener(
            engine: QueueingRemoteChangeApplier(queue: queue, driveID: driveID),
            client: DriveRuntime.makeClient(drive: drive),
            rootURI: drive.remoteRootURI, driveStore: driveStore, driveID: driveID,
            onChanged: {
                do {
                    try await DomainController.signalWorkingSet(driveID: driveID)
                } catch {
                    Log.shared.error("doorbell", "唤醒云盘 \(driveID) 的扩展失败：\(error)")
                }
            }
        )
        listeners[driveID] = listener
        Task { await listener.start() }
    }
}
