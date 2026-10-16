import Foundation

/// 本机存储或中转（relay）策略：分片经 Cloudreve 服务端上传，末块到达自动完成。
public struct LocalStrategy: ChunkStrategy {
    public init() {}

    public func upload(chunk: UploadChunk, data: Data, session: UploadSession, client: CloudreveClient) async throws -> String? {
        try await client.uploadChunk(sessionID: session.sessionID, index: chunk.index, data: data)
        return nil
    }

    public func complete(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {}
}
