import CloudreveAPI
import Foundation
import GRDB

/// 基于 `upload_session` 表的上传进度存储，按云盘隔离。
public struct GRDBUploadProgressStore: UploadProgressStore {
    private let db: any DatabaseWriter
    private let driveID: String

    public init(db: any DatabaseWriter, driveID: String) {
        self.db = db
        self.driveID = driveID
    }

    public func loadSession(uri: String) throws -> StoredUploadSession? {
        guard let record = try db.read({ db in try fetch(db, uri: uri) }) else { return nil }
        let decoder = JSONDecoder()
        return StoredUploadSession(
            uri: record.uri,
            size: record.size,
            policyType: record.policyType,
            session: try decoder.decode(UploadSession.self, from: Data(record.sessionJSON.utf8)),
            chunksDone: try decoder.decode([Int: String?].self, from: Data(record.chunksJSON.utf8)),
            createdAt: record.createdAt
        )
    }

    public func saveSession(_ session: StoredUploadSession) throws {
        let record = UploadSessionRecord(
            driveID: driveID,
            uri: session.uri,
            size: session.size,
            policyType: session.policyType,
            sessionJSON: try Self.json(session.session),
            chunksJSON: try Self.json(session.chunksDone),
            createdAt: session.createdAt
        )
        try db.write { db in try record.save(db) }
    }

    public func markChunk(uri: String, index: Int, etag: String?) throws {
        try db.write { db in
            guard var record = try fetch(db, uri: uri) else { return }
            var chunks = try JSONDecoder().decode([Int: String?].self, from: Data(record.chunksJSON.utf8))
            chunks[index] = .some(etag)
            record.chunksJSON = try Self.json(chunks)
            try record.update(db)
        }
    }

    public func deleteSession(uri: String) throws {
        try db.write { db in
            _ = try UploadSessionRecord.deleteOne(db, key: ["drive_id": driveID, "uri": uri])
        }
    }

    private func fetch(_ db: Database, uri: String) throws -> UploadSessionRecord? {
        try UploadSessionRecord.fetchOne(db, key: ["drive_id": driveID, "uri": uri])
    }

    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
