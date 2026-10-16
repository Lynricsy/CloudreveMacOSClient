import CloudreveAPI
import Foundation
import GRDB
import Testing
@testable import CloudreveSync

/// 记录调用的假引擎。
private actor FakeApplier: RemoteChangeApplier {
    private(set) var reconcileCount = 0
    private(set) var appliedEvents: [FileEvent] = []

    func reconcile() async throws -> Bool {
        reconcileCount += 1
        return true
    }

    func applyRemoteEvents(_ events: [FileEvent]) async throws -> Bool {
        appliedEvents += events
        return true
    }
}

/// 测试用睡眠：短间隔按预算立即返回，超出预算或 ≥300s（定期兜底）则挂起直到取消。
private actor SleepGate {
    private var budget: Int
    private(set) var durations: [Duration] = []
    private(set) var statusesAtSleep: [DriveStatus?] = []
    private let driveStore: DriveStore

    init(budget: Int, driveStore: DriveStore) {
        self.budget = budget
        self.driveStore = driveStore
    }

    func shouldReturn(_ duration: Duration) -> Bool {
        guard duration < .seconds(300) else { return false }
        durations.append(duration)
        statusesAtSleep.append(try? driveStore.get(id: DBFixtures.driveID)?.status)
        guard budget > 0 else { return false }
        budget -= 1
        return true
    }

    nonisolated func sleeper() -> RemoteEventListener.Sleeper {
        { duration in
            if await self.shouldReturn(duration) { return }
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

@Suite struct RemoteEventListenerTests {
    private struct Harness {
        let db: any DatabaseWriter
        let mock = MockTransport()
        let applier = FakeApplier()
        let changes = Counter()
        let attempts = Counter()
        let gate: SleepGate
        let listener: RemoteEventListener

        init(budget: Int) throws {
            db = try DBFixtures.database()
            let store = DriveStore(db: db)
            gate = SleepGate(budget: budget, driveStore: store)
            let credentials = InMemoryCredentialStore([DBFixtures.driveID: Credentials(
                accessToken: "a", refreshToken: "r", accessExpires: Date().addingTimeInterval(3600),
                refreshExpires: Date().addingTimeInterval(86400)
            )])
            let site = URL(string: "https://drive.example.com")!
            let mock = self.mock
            let tokens = TokenManager(driveID: DBFixtures.driveID, store: credentials) { token in
                try await CloudreveClient.refresh(site: site, transport: mock, refreshToken: token)
            }
            let client = CloudreveClient(site: site, transport: mock, tokens: tokens, clientID: UUID())
            let changes = self.changes
            listener = RemoteEventListener(
                engine: applier, client: client, rootURI: DBFixtures.rootURI, driveStore: store,
                driveID: DBFixtures.driveID, onChanged: { _ = await changes.increment() }, sleep: gate.sleeper()
            )
        }

        var status: DriveStatus? { try? DriveStore(db: db).get(id: DBFixtures.driveID)?.status }

        /// 第 n 次连接（从 1 起）返回的 SSE 文本；nil 表示连接失败。
        func routeStream(_ script: @escaping @Sendable (Int) -> String?) async {
            let attempts = self.attempts
            await mock.streamRoute("GET", "/api/v4/file/events") { _ in
                let attempt = await attempts.increment()
                guard let text = script(attempt) else { throw CloudreveAPIError.transport("connection refused") }
                return (HTTPResponseHead(status: 200, headers: ["Content-Type": "text/event-stream"]), [Data(text.utf8)])
            }
        }
    }

    static let subscribed = "event: subscribed\ndata: {}\n\n"

    @Test func subscribedTriggersReconcileAndEventsApply() async throws {
        let harness = try Harness(budget: 0)
        let eventText = #"event: event"# + "\n" + #"data: [{"type":"create","file_id":"f1","from":"/a.txt"}]"# + "\n\n"
        await harness.routeStream { _ in Self.subscribed + eventText }
        await harness.listener.start()
        try await eventually { await harness.applier.appliedEvents.count == 1 }
        await harness.listener.stop()
        #expect(await harness.applier.reconcileCount == 1)
        #expect(await harness.applier.appliedEvents.first?.fileID == "f1")
        #expect(await harness.changes.current == 2)
    }

    @Test func fiveFailuresMarksPushLost() async throws {
        let harness = try Harness(budget: 5)
        await harness.routeStream { attempt in attempt <= 5 ? nil : Self.subscribed }
        await harness.listener.start()
        try await eventually { await harness.applier.reconcileCount == 1 }
        await harness.listener.stop()
        let durations = await harness.gate.durations
        #expect(Array(durations.prefix(5)) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(60)])
        #expect(await harness.gate.statusesAtSleep[4] == .eventPushLost)
        #expect(harness.status == .active)
    }

    @Test func reconnectRequiredDoesNotBackOff() async throws {
        let harness = try Harness(budget: 0)
        await harness.routeStream { attempt in attempt == 1 ? "event: reconnect-required\ndata: {}\n\n" : Self.subscribed }
        await harness.listener.start()
        try await eventually { await harness.applier.reconcileCount == 1 }
        await harness.listener.stop()
        #expect(await harness.attempts.current >= 2)
    }

    @Test func notAuthenticatedStopsReconnecting() async throws {
        let harness = try Harness(budget: 10)
        await harness.mock.route("GET", "/api/v4/file/events") { _ in
            _ = await harness.attempts.increment()
            return .envelope(code: 401, msg: "login required")
        }
        await harness.mock.route("POST", "/api/v4/session/token/refresh") { _ in .envelope(code: 40020, msg: "invalid") }
        await harness.listener.start()
        try await eventually { harness.status == .credentialExpired }
        try await Task.sleep(for: .milliseconds(100))
        await harness.listener.stop()
        #expect(await harness.attempts.current == 1)
        #expect(await harness.gate.durations.isEmpty)
    }
}

/// 轮询等待条件成立（最多 5 秒）。
private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("条件在超时内未成立")
}

/// 并发安全计数器。
private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
    var current: Int { value }
}
