import Foundation

/// 本机存储或中转（relay）策略：分片经 Cloudreve 服务端上传，末块到达自动完成。
public struct LocalStrategy: ChunkStrategy {
    public init() {}

    public func upload(chunk: UploadChunk, body: HTTPBody, session: UploadSession, client: CloudreveClient) async throws -> String? {
        try await client.uploadChunk(sessionID: session.sessionID, index: chunk.index, body: body)
        return nil
    }
}
