import CloudreveAPI
import Foundation
import GRDB
import Synchronization
import Testing
@testable import CloudreveSync

/// 引擎测试环境：内存库（含云盘与根条目）+ `TestServer` + 已登录客户端 + 引擎。
struct EngineHarness: Sendable {
    static let site = URL(string: "https://drive.example.com")!

    let db: any DatabaseWriter
    let server: TestServer
    let engine: SyncEngine
    let clock: DatabaseTestClock
    let credentials: InMemoryCredentialStore

    var driveID: String { DBFixtures.driveID }
    var rootID: String { DBFixtures.rootID }
    var mock: MockTransport { server.mock }
    var items: ItemStore { ItemStore(db: db) }
    var changeLog: ChangeLog { ChangeLog(db: db) }
    var transfers: TransferStore { TransferStore(db: db) }

    /// `remoteRoot` 为挂载根（默认服务端根 `/`）；非默认时调用方需先在服务端建出该目录。
    static func make(remoteRoot: CloudreveURI = DBFixtures.rootURI) async throws -> EngineHarness {
        let db = try DBFixtures.database(remoteRoot: remoteRoot)
        let server = await TestServer.start(rootID: DBFixtures.rootID)
        let valid = Credentials(
            accessToken: "access", refreshToken: "refresh",
            accessExpires: Date().addingTimeInterval(3600), refreshExpires: Date().addingTimeInterval(86400)
        )
        let credentials = InMemoryCredentialStore([DBFixtures.driveID: valid])
        let tokens = TokenManager(driveID: DBFixtures.driveID, store: credentials) { refreshToken in
            try await CloudreveClient.refresh(site: site, transport: server.mock, refreshToken: refreshToken)
        }
        let client = CloudreveClient(site: site, transport: server.mock, tokens: tokens, clientID: DBFixtures.drive().clientID)
        let uploader = Uploader(
            client: client, store: GRDBUploadProgressStore(db: db, driveID: DBFixtures.driveID), sleep: { _ in }
        )
        let clock = DatabaseTestClock()
        let engine = try SyncEngine(driveID: DBFixtures.driveID, db: db, client: client, uploader: uploader, now: clock.provider)
        return EngineHarness(db: db, server: server, engine: engine, clock: clock, credentials: credentials)
    }

    /// 完整列一个目录（全部分页）。
    func enumerateAll(_ folderID: String) async throws {
        var token: String?
        repeat {
            token = try await engine.enumerateFolder(id: folderID, pageToken: token).nextToken
        } while token != nil
    }

    func record(_ id: String) throws -> ItemRecord? {
        try items.get(driveID: driveID, id: id)
    }

    func record(path: String) throws -> ItemRecord? {
        try items.getByURI(driveID: driveID, uri: .my(path))
    }

    /// `seq > after` 的变更日志（item id, kind）。
    func logged(after seq: Int64 = 0) throws -> [LoggedChange] {
        try changeLog.changes(driveID: driveID, afterSeq: seq, limit: 100_000).map { LoggedChange(id: $0.itemID, kind: $0.kind) }
    }

    func latestSeq() throws -> Int64 {
        try changeLog.latestSeq(driveID: driveID)
    }

    /// 镜像中全部非根条目的 uri；断言其中没有扫描期暂存的占位路径（以 `\u{1}` 开头的首段）。
    func mirrorPaths() throws -> [CloudreveURI] {
        let uris = try items.descendants(driveID: driveID, uriPrefix: DBFixtures.rootURI).map(\.uri)
        #expect(uris.allSatisfy { !($0.segments.first?.unicodeScalars.first == "\u{1}") }, "\(uris)")
        return uris
    }

    func driveStatus() throws -> DriveStatus? {
        try DriveStore(db: db).get(id: driveID)?.status
    }

    /// 写入临时文件（作为 File Provider 交给扩展的本地内容）。
    static func tempFile(_ content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ck-engine-\(UUID().uuidString)")
        try content.write(to: url)
        return url
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ck-download-\(UUID().uuidString)")
    }
}

/// 便于断言的变更日志条目。
struct LoggedChange: Hashable, CustomStringConvertible {
    let id: String
    let kind: ChangeKind

    var description: String { "\(kind.rawValue) \(id)" }
}

/// 不关心进度时使用。
let ignoreProgress: SyncEngine.ProgressHandler = { _, _ in }

/// 记录进度回调的已完成字节数。
final class ProgressRecorder: Sendable {
    private let values = Mutex<[Int64]>([])

    var handler: SyncEngine.ProgressHandler {
        { done, _ in self.values.withLock { $0.append(done) } }
    }

    var last: Int64? { values.withLock { $0.last } }
}

extension SyncError {
    /// 是否为 `.filenameCollision`（不论是否附带冲突条目）。
    var isFilenameCollision: Bool {
        if case .filenameCollision = self { return true }
        return false
    }

    /// `.filenameCollision` 附带的冲突条目 id；其他错误或未附带时为 nil。
    var collidingItemID: String? {
        if case .filenameCollision(let existing) = self { return existing?.id }
        return nil
    }
}
