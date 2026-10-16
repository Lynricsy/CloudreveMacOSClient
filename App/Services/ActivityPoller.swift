import CloudreveAPI
import CloudreveSync
import Foundation

/// App 常驻的 30 秒轮询：根据共享库状态发送「需要重新登录」与「文件冲突」通知。只读本地库，不访问网络。
@MainActor
final class ActivityPoller {
    static let interval: Duration = .seconds(30)
    /// 同步引擎写入冲突失败记录时使用的错误前缀（见 `SyncEngine.modify`）。
    static let conflictPrefix = "版本冲突"

    private let driveStore: DriveStore
    private let transferStore: TransferStore
    private let preferences: GeneralPreferences
    /// 已提醒过凭证过期的云盘；恢复 active 后移除，再次过期会重新提醒。
    private var notifiedExpired: Set<String> = []
    private var task: Task<Void, Never>?

    init(driveStore: DriveStore, transferStore: TransferStore, preferences: GeneralPreferences) {
        self.driveStore = driveStore
        self.transferStore = transferStore
        self.preferences = preferences
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: ActivityPoller.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        do {
            try await checkCredentials()
            try await checkConflicts()
        } catch {
            Log.shared.error("ActivityPoller", "轮询失败：\(error.localizedDescription)")
        }
    }

    private func checkCredentials() async throws {
        let drives = try driveStore.all()
        notifiedExpired.formIntersection(drives.map(\.id))
        for drive in drives {
            guard drive.status == .credentialExpired else {
                notifiedExpired.remove(drive.id)
                continue
            }
            guard notifiedExpired.insert(drive.id).inserted else { continue }
            if preferences.notifyCredentialExpired {
                await NotificationService.notifyCredentialExpired(driveID: drive.id, driveName: drive.name)
            }
        }
    }

    private func checkConflicts() async throws {
        let failures = try transferStore.unnotifiedFailures()
        guard !failures.isEmpty else { return }
        if preferences.notifyFileConflict {
            for failure in failures {
                guard let message = failure.error, message.hasPrefix(Self.conflictPrefix) else { continue }
                await NotificationService.notifyConflict(transferID: failure.id, fileName: failure.name, message: message)
            }
        }
        try transferStore.markNotified(ids: failures.map(\.id))
    }
}
