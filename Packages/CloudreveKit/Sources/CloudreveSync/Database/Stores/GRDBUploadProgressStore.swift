import CloudreveAPI
import Foundation
import GRDB

/// 基于 `upload_session` 表的上传进度存储，按云盘隔离。
///
/// 续传状态（已完成分片、分片摘要、覆盖方式、收尾阶段）整体以 JSON 对象存于 `chunks_json` 列，无需改表结构。
/// 旧版本该列只有 `[Int: String?]`：按旧格式读出且不带摘要与覆盖方式，上传器据此判定不可复用并新建会话。
public struct GRDBUploadProgressStore: UploadProgressStore {
    private let db: any DatabaseWriter
    private let driveID: String

    public init(db: any DatabaseWriter, driveID: String) {
        self.db = db
        self.driveID = driveID
    }

    public func loadSession(uri: String) throws -> StoredUploadSession? {
        guard let record = try db.read({ db in try fetch(db, uri: uri) }) else { return nil }
        let progress = try ResumeState.decode(record.chunksJSON)
        return StoredUploadSession(
            uri: record.uri,
            size: record.size,
            policyType: record.policyType,
            session: try JSONDecoder().decode(UploadSession.self, from: Data(record.sessionJSON.utf8)),
            overwrite: progress.overwrite,
            chunksDone: progress.chunks,
            chunkDigests: progress.digests,
            stage: progress.stage,
            createdAt: record.createdAt
        )
    }

    public func saveSession(_ session: StoredUploadSession) throws {
        let progress = ResumeState(
            chunks: session.chunksDone, digests: session.chunkDigests, overwrite: session.overwrite, stage: session.stage
        )
        let record = UploadSessionRecord(
            driveID: driveID,
            uri: session.uri,
            size: session.size,
            policyType: session.policyType,
            sessionJSON: try Self.json(session.session),
            chunksJSON: try Self.json(progress),
            createdAt: session.createdAt
        )
        try db.write { db in try record.save(db) }
    }

    public func markChunk(uri: String, index: Int, etag: String?, digest: String) throws {
        try update(uri: uri) { progress in
            progress.chunks[index] = .some(etag)
            progress.digests[index] = digest
        }
    }

    public func markStage(uri: String, stage: UploadStage) throws {
        try update(uri: uri) { progress in
            if progress.stage < stage { progress.stage = stage }
        }
    }

    public func deleteSession(uri: String) throws {
        try db.write { db in
            _ = try UploadSessionRecord.deleteOne(db, key: ["drive_id": driveID, "uri": uri])
        }
    }

    /// 在同一个写事务内读改写续传状态；会话不存在时忽略。
    private func update(uri: String, _ mutate: (inout ResumeState) -> Void) throws {
        try db.write { db in
            guard var record = try fetch(db, uri: uri) else { return }
            var progress = try ResumeState.decode(record.chunksJSON)
            mutate(&progress)
            record.chunksJSON = try Self.json(progress)
            try record.update(db)
        }
    }

    private func fetch(_ db: Database, uri: String) throws -> UploadSessionRecord? {
        try UploadSessionRecord.fetchOne(db, key: ["drive_id": driveID, "uri": uri])
    }

    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

/// `chunks_json` 列的内容。
private struct ResumeState: Codable {
    var chunks: [Int: String?]
    var digests: [Int: String]
    var overwrite: OverwriteMode?
    var stage: UploadStage

    static func decode(_ json: String) throws -> ResumeState {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(ResumeState.self, from: data) { return state }
        // 旧格式：只有已完成分片
        let chunks = try decoder.decode([Int: String?].self, from: data)
        return ResumeState(chunks: chunks, digests: [:], overwrite: nil, stage: .uploading)
    }
}
