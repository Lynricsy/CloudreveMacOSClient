import CloudreveAPI
import Foundation
import GRDB
import Testing
@testable import CloudreveSync

enum UploadStoreFixtures {
    static func stored(uri: String, size: Int64 = 10) -> StoredUploadSession {
        let session = UploadSession(
            sessionID: "sid", uploadID: "upid", chunkSize: 4, expires: 1_800_000_000,
            uploadURLs: ["https://s3.example.com/part1"], credential: "cred", completeURL: "https://s3.example.com/complete",
            storagePolicy: StoragePolicy(id: "p1", name: "S3", type: "s3", maxSize: 0, relay: false, chunkConcurrency: 2),
            uri: uri, callbackSecret: "secret"
        )
        return StoredUploadSession(uri: uri, size: size, policyType: "s3", session: session, createdAt: DBFixtures.epoch)
    }
}

@Suite struct GRDBUploadProgressStoreTests {
    private let uri = "cloudreve://my/a.txt"

    @Test func roundTripWithChunks() throws {
        let db = try DBFixtures.database(drives: ["d1", "d2"])
        let store = GRDBUploadProgressStore(db: db, driveID: "d1")
        let other = GRDBUploadProgressStore(db: db, driveID: "d2")
        #expect(try store.loadSession(uri: uri) == nil)

        let original = UploadStoreFixtures.stored(uri: uri)
        try store.saveSession(original)
        #expect(try store.loadSession(uri: uri) == original)
        #expect(try other.loadSession(uri: uri) == nil)

        try store.markChunk(uri: uri, index: 0, etag: "etag-0")
        try store.markChunk(uri: uri, index: 2, etag: nil)
        // 不存在的会话：忽略
        try store.markChunk(uri: "cloudreve://my/none", index: 0, etag: nil)
        let loaded = try #require(try store.loadSession(uri: uri))
        let expected: [Int: String?] = [0: "etag-0", 2: nil]
        #expect(loaded.chunksDone == expected)
        #expect(loaded.session == original.session)

        // 覆盖保存
        var replaced = original
        replaced.size = 20
        try store.saveSession(replaced)
        #expect(try store.loadSession(uri: uri)?.chunksDone.isEmpty == true)
        #expect(try store.loadSession(uri: uri)?.size == 20)

        try store.deleteSession(uri: uri)
        #expect(try store.loadSession(uri: uri) == nil)
    }
}
