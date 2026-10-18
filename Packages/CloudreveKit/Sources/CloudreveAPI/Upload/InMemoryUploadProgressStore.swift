import Foundation
import Synchronization

/// 内存上传进度存储（测试用）。
public final class InMemoryUploadProgressStore: UploadProgressStore {
    private let sessions = Mutex<[String: StoredUploadSession]>([:])

    public init() {}

    public func loadSession(uri: String) throws -> StoredUploadSession? {
        sessions.withLock { $0[uri] }
    }

    public func saveSession(_ session: StoredUploadSession) throws {
        sessions.withLock { $0[session.uri] = session }
    }

    public func markChunk(uri: String, index: Int, etag: String?, digest: String) throws {
        sessions.withLock { sessions in
            sessions[uri]?.chunksDone[index] = .some(etag)
            sessions[uri]?.chunkDigests[index] = digest
        }
    }

    public func markStage(uri: String, stage: UploadStage) throws {
        sessions.withLock { sessions in
            guard let current = sessions[uri]?.stage, current < stage else { return }
            sessions[uri]?.stage = stage
        }
    }

    public func deleteSession(uri: String) throws {
        _ = sessions.withLock { $0.removeValue(forKey: uri) }
    }
}
