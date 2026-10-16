import CloudreveAPI
import CloudreveSync
import FileProvider
import Foundation

/// 一个域（云盘）在扩展进程内的运行时对象。
struct ExtensionRuntime: Sendable {
    let driveID: String
    let rootID: String
    let engine: SyncEngine
    let client: CloudreveClient
    let listener: RemoteEventListener
    let manager: SendableBox<NSFileProviderManager>

    /// 打开共享数据库并装配引擎与远端监听。
    static func make(domain: NSFileProviderDomain) throws -> ExtensionRuntime {
        let driveID = domain.identifier.rawValue
        let db = try SyncDatabase.open(at: AppGroupPaths.databaseURL)
        OSLogSink.install(minimum: AppSettings(db: db).logLevel)
        let driveStore = DriveStore(db: db)
        guard let drive = try driveStore.get(id: driveID) else {
            throw SyncError.cannotSynchronize("找不到云盘 \(driveID) 的配置，请在 Cloudreve 中重新添加")
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw SyncError.cannotSynchronize("无法获取 File Provider 管理器")
        }
        let client = DriveRuntime.makeClient(drive: drive)
        let uploader = Uploader(client: client, store: GRDBUploadProgressStore(db: db, driveID: driveID))
        let engine = try SyncEngine(driveID: driveID, db: db, client: client, uploader: uploader)
        let managerBox = SendableBox(manager)
        let listener = RemoteEventListener(
            engine: engine, client: client, rootURI: drive.remoteRootURI, driveStore: driveStore, driveID: driveID,
            onChanged: {
                do {
                    try await managerBox.value.signalEnumerator(for: .workingSet)
                } catch {
                    Log.shared.error("extension", "通知系统刷新 working set 失败：\(error)")
                }
            }
        )
        return ExtensionRuntime(
            driveID: driveID, rootID: drive.rootFileID, engine: engine, client: client, listener: listener, manager: managerBox
        )
    }

    func item(_ item: SyncItem) -> FileProviderItem {
        FileProviderItem(item, rootID: rootID)
    }

    /// 系统标识符原始值 → 引擎 id（在 Task 外取 rawValue，避免捕获非 Sendable 的系统类型）。
    func syncID(raw: String) -> String {
        FileProviderBridge.syncID(NSFileProviderItemIdentifier(raw), rootID: rootID)
    }
}
