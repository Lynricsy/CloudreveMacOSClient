import CloudreveAPI
import Foundation

/// 远端变更监听：订阅挂载根的 SSE（服务端沿祖先链推送，订阅根即覆盖整棵树），
/// 并定期全量 reconcile 兜底（推送可能被服务端丢弃）。
public actor RemoteEventListener {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// 连续失败达到该次数即视为推送中断。
    static let maxBackoffFailures = 5
    static let pushLostRetryInterval: Duration = .seconds(60)
    static let reconcileInterval: Duration = .seconds(3600)
    static let pushLostReconcileInterval: Duration = .seconds(300)

    private let engine: any RemoteChangeApplier
    private let client: CloudreveClient
    private let rootURI: CloudreveURI
    private let driveStore: DriveStore
    private let driveID: String
    private let onChanged: @Sendable () async -> Void
    private let sleep: Sleeper
    private var subscription: Task<Void, Never>?
    private var periodic: Task<Void, Never>?

    public init(
        engine: any RemoteChangeApplier, client: CloudreveClient, rootURI: CloudreveURI, driveStore: DriveStore,
        driveID: String, onChanged: @escaping @Sendable () async -> Void,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.client = client
        self.rootURI = rootURI
        self.driveStore = driveStore
        self.driveID = driveID
        self.onChanged = onChanged
        self.sleep = sleep
    }

    /// 启动订阅与定期兜底；已启动时无操作。
    public func start() {
        guard subscription == nil else { return }
        subscription = Task { await self.subscriptionLoop() }
        periodic = Task { await self.periodicReconcileLoop() }
    }

    public func stop() {
        subscription?.cancel()
        periodic?.cancel()
        subscription = nil
        periodic = nil
    }

    // MARK: - 订阅

    private func subscriptionLoop() async {
        var failures = 0
        while !Task.isCancelled {
            let (outcome, connected) = await consumeStream()
            // 任一次成功连接后计数清零
            if connected { failures = 0 }
            switch outcome {
            case .cancelled, .unauthenticated:
                return
            case .reconnectNow:
                failures = 0
                continue
            case .ended:
                failures += 1
            }
            let delay: Duration
            if failures >= Self.maxBackoffFailures {
                setStatus(.eventPushLost, onlyIf: .active)
                delay = Self.pushLostRetryInterval
            } else {
                delay = .seconds(min(32, 1 << (failures - 1)))
            }
            Log.shared.info("events", "云盘 \(driveID) 推送断开（连续 \(failures) 次），\(delay) 后重连")
            do { try await sleep(delay) } catch { return }
        }
    }

    private enum StreamOutcome {
        case ended, reconnectNow, cancelled, unauthenticated
    }

    /// 消费一次连接直到结束；收到首个事件即视为连接成功。
    private func consumeStream() async -> (StreamOutcome, connected: Bool) {
        var connected = false
        let outcome = await consume(markConnected: { connected = true })
        return (outcome, connected)
    }

    private func consume(markConnected: () -> Void) async -> StreamOutcome {
        do {
            for try await event in client.fileEvents(uri: rootURI) {
                markConnected()
                if try await handle(event) == .reconnectNow { return .reconnectNow }
            }
            return Task.isCancelled ? .cancelled : .ended
        } catch is CancellationError {
            return .cancelled
        } catch {
            if case SyncError.notAuthenticated? = SyncErrorMapper.map(error) as? SyncError {
                setStatus(.credentialExpired, onlyIf: nil)
                Log.shared.error("events", "云盘 \(driveID) 凭证失效，停止推送订阅")
                return .unauthenticated
            }
            Log.shared.info("events", "云盘 \(driveID) 推送连接错误：\(error)")
            return Task.isCancelled ? .cancelled : .ended
        }
    }

    private func handle(_ event: SSEEvent) async throws -> StreamOutcome? {
        switch event.name {
        case "subscribed":
            setStatus(.active, onlyIf: nil)
            await reconcileAndNotify()
        case "resumed":
            setStatus(.active, onlyIf: nil)
        case "reconnect-required":
            return .reconnectNow
        case "event":
            let events = FileEvent.decodeList(Data(event.data.utf8))
            guard !events.isEmpty else { return nil }
            do {
                if try await engine.applyRemoteEvents(events) { await onChanged() }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.shared.error("events", "应用远端事件失败：\(error)")
            }
        default:
            break
        }
        return nil
    }

    // MARK: - 定期兜底

    private func periodicReconcileLoop() async {
        while !Task.isCancelled {
            let status = (try? driveStore.get(id: driveID))?.status
            let interval = status == .eventPushLost ? Self.pushLostReconcileInterval : Self.reconcileInterval
            do { try await sleep(interval) } catch { return }
            guard (try? driveStore.get(id: driveID))?.status != .credentialExpired else { continue }
            await reconcileAndNotify()
        }
    }

    private func reconcileAndNotify() async {
        do {
            if try await engine.reconcile() { await onChanged() }
        } catch {
            Log.shared.error("events", "云盘 \(driveID) reconcile 失败：\(error)")
        }
    }

    /// 更新云盘状态；`onlyIf` 非 nil 时仅在当前状态匹配时更新。
    private func setStatus(_ status: DriveStatus, onlyIf expected: DriveStatus?) {
        guard let current = (try? driveStore.get(id: driveID))?.status, current != status else { return }
        if let expected, current != expected { return }
        try? driveStore.updateStatus(id: driveID, status)
    }
}
