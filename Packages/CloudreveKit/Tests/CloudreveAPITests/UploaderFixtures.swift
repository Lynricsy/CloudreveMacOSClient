#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Synchronization
import Testing
@testable import CloudreveAPI

/// 上传测试共用的会话、文件与记录工具。
enum UploaderFixtures {
    static let sessionID = "s1"
    static let secret = "secret"
    static let uri = CloudreveURI.my("docs/a.txt")

    /// 小写十六进制 SHA-256（与上传器记录的分片摘要格式一致）。
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let file = FileResponse(
        type: 0, id: "f1", name: "a.txt", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), size: 10, path: "/docs/a.txt", primaryEntity: "e2"
    )

    static func client(_ mock: MockTransport) -> CloudreveClient {
        Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
    }

    static func session(
        type: String, chunkSize: Int64, relay: Bool? = nil, concurrency: Int? = 1, uploadURLs: [String]? = nil,
        credential: String? = nil, completeURL: String? = nil, expiresIn: TimeInterval = 3600
    ) -> UploadSession {
        UploadSession(
            sessionID: sessionID, chunkSize: chunkSize, expires: Int64(Date().timeIntervalSince1970 + expiresIn),
            uploadURLs: uploadURLs, credential: credential, completeURL: completeURL,
            storagePolicy: StoragePolicy(id: "p1", name: "policy", type: type, relay: relay, chunkConcurrency: concurrency),
            uri: uri.description, callbackSecret: secret, mimeType: "text/plain"
        )
    }

    /// 内容为 0, 1, 2, … 的字节。
    static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 256) })
    }

    static func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    /// 把请求体解析为 JSON 对象。
    static func json(_ data: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try #require(data))
        return try #require(object as? [String: Any])
    }

    static func routeSession(_ mock: MockTransport, _ session: UploadSession) async {
        await mock.route("PUT", "/api/v4/file/upload") { _ in try .envelope(encoding: session) }
    }

    static func routeFileInfo(_ mock: MockTransport) async {
        await mock.route("GET", "/api/v4/file/info") { _ in try .envelope(encoding: file) }
    }

    /// 依次返回 `ids` 对应的会话（最后一个重复使用），用于区分新建与复用。
    static func routeSessions(_ mock: MockTransport, ids: [String], make: @escaping @Sendable (String) -> UploadSession) async {
        let counter = Counter()
        await mock.route("PUT", "/api/v4/file/upload") { _ in
            let index = min(await counter.increment(), ids.count) - 1
            return try .envelope(encoding: make(ids[index]))
        }
    }

    static let lastModified = Date(timeIntervalSince1970: 1_700_000_000)

    static func upload(
        _ uploader: Uploader, data: Data, overwrite: OverwriteMode = .create, lastModified: Date = lastModified,
        progress: ProgressLog = ProgressLog()
    ) async throws -> FileResponse {
        let fileURL = try tempFile(data)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try await uploader.upload(
            fileURL: fileURL, size: Int64(data.count), to: uri, mimeType: "text/plain",
            lastModified: lastModified, overwrite: overwrite,
            progress: { done, _ in progress.append(done) }
        )
    }
}

/// 线程安全的记录器（在路由处理器中收集观察结果）。
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
}

/// 记录 `sleep` 调用（测试不真正等待）。
actor SleepLog {
    private(set) var durations: [Duration] = []
    func append(_ duration: Duration) { durations.append(duration) }
}

/// 记录进度回调的已完成字节数。
final class ProgressLog: Sendable {
    private let storage = Mutex<[Int64]>([])
    func append(_ done: Int64) { storage.withLock { $0.append(done) } }
    var values: [Int64] { storage.withLock { $0 } }
}
