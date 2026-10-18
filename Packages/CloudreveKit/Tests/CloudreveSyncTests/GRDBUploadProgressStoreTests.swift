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

        try store.markChunk(uri: uri, index: 0, etag: "etag-0", digest: "d0")
        try store.markChunk(uri: uri, index: 2, etag: nil, digest: "d2")
        // 不存在的会话：忽略
        try store.markChunk(uri: "cloudreve://my/none", index: 0, etag: nil, digest: "dx")
        let loaded = try #require(try store.loadSession(uri: uri))
        let expected: [Int: String?] = [0: "etag-0", 2: nil]
        #expect(loaded.chunksDone == expected)
        #expect(loaded.session == original.session)
        #expect(loaded.chunkDigests == [0: "d0", 2: "d2"])

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

extension GRDBUploadProgressStoreTests {
    /// 旧版本 `chunks_json` 只有 `[Int: String?]`：按旧格式读出，无摘要、无覆盖方式、阶段为上传中（上传器据此新建会话）。
    @Test func loadsLegacyChunksJSON() throws {
        let db = try DBFixtures.database(drives: ["d1"])
        let store = GRDBUploadProgressStore(db: db, driveID: "d1")
        let uri = "cloudreve://my/legacy.txt"
        try store.saveSession(UploadStoreFixtures.stored(uri: uri))
        try db.write { db in
            try db.execute(
                sql: #"UPDATE upload_session SET chunks_json = '{"0":"etag-0"}' WHERE drive_id = 'd1' AND uri = ?"#,
                arguments: [uri]
            )
        }
        let loaded = try #require(try store.loadSession(uri: uri))
        let expected: [Int: String?] = [0: "etag-0"]
        #expect(loaded.chunksDone == expected)
        #expect(loaded.chunkDigests.isEmpty)
        #expect(loaded.overwrite == nil)
        #expect(loaded.stage == .uploading)
    }
}
