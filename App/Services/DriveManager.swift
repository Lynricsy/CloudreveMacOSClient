import AppKit
import CloudreveAPI
import CloudreveSync
import Foundation
import Observation

/// 菜单栏 App 的中心状态：读共享库展示云盘与传输活动，并封装域管理操作。
///
/// 数据库调用是同步的 GRDB 小查询，直接在主 actor 上执行；网络请求（容量刷新）全部 `await`，不阻塞主线程。
@MainActor
@Observable
final class DriveManager {
    static let pollInterval: Duration = .seconds(1)
    /// 弹窗打开时容量超过 5 分钟未更新则刷新。
    static let capacityMaxAge: TimeInterval = 5 * 60
    static let recentLimit = 50

    private(set) var drives: [DriveSummary] = []
    private(set) var runningTransfers: [TransferRow] = []
    private(set) var recentTransfers: [TransferRow] = []
    private(set) var runningCount = 0
    /// 尚未在系统设置中启用「文件提供程序」的云盘（弹窗打开时刷新）。
    private(set) var disabledDriveIDs: Set<String> = []
    /// 弹窗按云盘过滤；nil 表示全部。
    private(set) var selectedDriveID: String?
    /// 最近一次界面操作失败的提示（由视图以 alert 展示）。
    var actionError: String?

    @ObservationIgnored let preferences: GeneralPreferences
    @ObservationIgnored let driveStore: DriveStore
    @ObservationIgnored let transferStore: TransferStore
    @ObservationIgnored private let remoteEvents: RemoteEventQueue
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var samples: [String: TransferSample] = [:]
    @ObservationIgnored private var refreshingCapacity: Set<String> = []
    @ObservationIgnored private let doorbell = RemoteChangeDoorbell()

    init() {
        // 共享库打不开时 App 无法工作（也无法与扩展协作），属于不可恢复的环境错误。
        let opened = Result { try SyncDatabase.open(at: AppGroupPaths.databaseURL) }
        guard case .success(let db) = opened else {
            fatalError("无法打开共享数据库：\(opened)")
        }
        driveStore = DriveStore(db: db)
        transferStore = TransferStore(db: db)
        remoteEvents = RemoteEventQueue(db: db)
        preferences = GeneralPreferences(settings: AppSettings(db: db))
        reload()
        syncDoorbell()
    }

    var isShowingActionError: Bool {
        get { actionError != nil }
        set { if !newValue { actionError = nil } }
    }

    func drive(id: String) -> DriveSummary? {
        drives.first { $0.id == id }
    }

    func select(driveID: String?) {
        selectedDriveID = driveID
        reload()
    }

    // MARK: - 读取与轮询

    /// 重新读取云盘与最近传输（并计算进行中任务的速度）。
    func reload() {
        do {
            drives = try driveStore.all().map(DriveSummary.init(record:))
            if let selected = selectedDriveID, !drives.contains(where: { $0.id == selected }) {
                selectedDriveID = nil
            }
            let now = Date()
            let rows = try transferStore.recent(driveID: selectedDriveID, limit: Self.recentLimit).map { record in
                TransferRow(record: record, bytesPerSecond: speed(for: record, now: now))
            }
            runningTransfers = rows.filter { $0.state == .running }
            recentTransfers = rows.filter { $0.state != .running }
            runningCount = try transferStore.runningCount(driveID: selectedDriveID)
            let runningIDs = Set(runningTransfers.map(\.id))
            samples = samples.filter { runningIDs.contains($0.key) }
        } catch {
            Log.shared.error("DriveManager", "读取共享库失败：\(error.localizedDescription)")
        }
    }

    /// 弹窗出现时开始每秒刷新，并按需刷新过期的容量。
    func startPopupPolling() {
        refreshStaleCapacities()
        Task { await refreshEnablement() }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reload()
                try? await Task.sleep(for: DriveManager.pollInterval)
            }
        }
    }

    func stopPopupPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 重新读取各云盘域的启用状态；读取失败时保持现状。
    func refreshEnablement() async {
        do {
            disabledDriveIDs = try await DomainController.disabledDriveIDs()
        } catch {
            Log.shared.info("DriveManager", "读取域启用状态失败：\(error.localizedDescription)")
        }
    }

    /// 打开「系统设置 → 通用 → 登录项与扩展」，用户在其中启用「文件提供程序」。
    func openFileProviderSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 两次采样间隔不足 0.5 秒时沿用上次速度，避免非轮询触发的 reload 造成跳变。
    private func speed(for record: TransferRecord, now: Date) -> Double {
        guard record.state == .running else { return 0 }
        guard let previous = samples[record.id] else {
            samples[record.id] = TransferSample(bytes: record.doneBytes, time: now, bytesPerSecond: 0)
            return 0
        }
        let interval = now.timeIntervalSince(previous.time)
        guard interval >= 0.5 else { return previous.bytesPerSecond }
        let speed = max(0, Double(record.doneBytes - previous.bytes) / interval)
        samples[record.id] = TransferSample(bytes: record.doneBytes, time: now, bytesPerSecond: speed)
        return speed
    }

    // MARK: - 容量

    private func refreshStaleCapacities() {
        let now = Date()
        for drive in drives where drive.isCapacityStale(now: now, maxAge: Self.capacityMaxAge) {
            Task { await self.refreshCapacity(driveID: drive.id) }
        }
    }

    /// 拉取容量并写库；凭证失效时把云盘标为需要重新登录。
    func refreshCapacity(driveID: String) async {
        guard !refreshingCapacity.contains(driveID), let record = try? driveStore.get(id: driveID) else { return }
        refreshingCapacity.insert(driveID)
        defer { refreshingCapacity.remove(driveID) }
        let client = DriveRuntime.makeClient(drive: record)
        do {
            let capacity = try await client.capacity()
            try driveStore.updateCapacity(id: driveID, total: capacity.total, used: capacity.used)
        } catch CloudreveAPIError.credentialInvalid {
            try? driveStore.updateStatus(id: driveID, .credentialExpired)
        } catch {
            Log.shared.info("DriveManager", "刷新容量失败：\(error.localizedDescription)")
        }
        reload()
    }

    // MARK: - 添加 / 重新登录 / 移除

    /// 写入云盘与根目录行，再注册 File Provider 域；注册失败则回滚数据库。
    func addDrive(_ setup: DriveSetup) async throws {
        let drive = setup.driveRecord(now: Date())
        try driveStore.insert(drive, rootItem: setup.rootItem())
        do {
            try await DomainController.add(driveID: drive.id, name: drive.name)
        } catch {
            try? driveStore.delete(id: drive.id)
            reload()
            throw error
        }
        reload()
        syncDoorbell()
    }

    /// 重新登录成功：恢复 active，解除系统节流并重连域。
    func completeReauthorization(driveID: String) async throws {
        try driveStore.updateStatus(id: driveID, .active)
        reload()
        if let record = try driveStore.get(id: driveID) {
            doorbell.restart(record, queue: remoteEvents, driveStore: driveStore)
        }
        try await DomainController.errorResolved(driveID: driveID)
        try await DomainController.reconnect(driveID: driveID)
    }

    /// 移除云盘：先移除域（含本地副本），再删库记录，最后删钥匙串凭证。
    func removeDrive(id: String) async {
        do {
            try await DomainController.remove(driveID: id)
            try driveStore.delete(id: id)
            try KeychainCredentialStore().delete(driveID: id)
        } catch {
            report(error)
        }
        reload()
        syncDoorbell()
    }

    /// 门铃订阅与库中云盘对齐（读库失败时保持现状）。
    private func syncDoorbell() {
        guard let records = try? driveStore.all() else { return }
        doorbell.sync(with: records, queue: remoteEvents, driveStore: driveStore)
    }

    func updateIgnorePatterns(id: String, _ patterns: [String]) {
        do {
            try driveStore.updateIgnorePatterns(id: id, patterns)
        } catch {
            report(error)
        }
        reload()
    }

    // MARK: - Finder

    func syncNow(id: String) async {
        do {
            try await DomainController.signalWorkingSet(driveID: id)
        } catch {
            report(error)
        }
    }

    func openInFinder(id: String) async {
        do {
            let url = try await DomainController.userVisibleURL(driveID: id, item: nil)
            NSWorkspace.shared.open(url)
        } catch {
            report(error)
        }
    }

    /// 弹窗底部按钮：打开当前选中的云盘，未选中时打开第一个。
    func openPreferredInFinder() async {
        guard let id = selectedDriveID ?? drives.first?.id else { return }
        await openInFinder(id: id)
    }

    /// 在 Finder 中定位传输对应的文件；没有条目 id（或为根目录）时打开云盘根目录。
    func reveal(_ transfer: TransferRow) async {
        let rootID = drive(id: transfer.driveID)?.rootFileID
        let item = transfer.itemID.flatMap { $0 == rootID ? nil : $0 }
        do {
            let url = try await DomainController.userVisibleURL(driveID: transfer.driveID, item: item)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.shared.error("DriveManager", message)
        actionError = message
    }
}
