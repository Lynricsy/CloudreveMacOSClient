import Foundation

/// S3 兼容系策略（s3/ks3/cos/obs/oss）：分片 PUT 到预签名地址，取 etag；完成时向 `completeURL` 提交合并请求。
public struct S3FamilyStrategy: ChunkStrategy {
    /// 具体厂商，`rawValue` 即策略类型与回调路径段。
    public enum Variant: String, Sendable, CaseIterable {
        case s3, ks3, cos, obs, oss
    }

    public let variant: Variant

    public init(variant: Variant) {
        self.variant = variant
    }

    public func upload(chunk: UploadChunk, data: Data, session: UploadSession, client: CloudreveClient) async throws -> String? {
        let url = try StorageHTTP.uploadURL(session, index: chunk.index)
        let request = HTTPRequest(method: "PUT", url: url, headers: ["Content-Type": StorageHTTP.octetStream], body: .data(data))
        let response = try await StorageHTTP.send(request, client: client)
        return StorageHTTP.etag(response)
    }

    public func complete(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {
        let url = try StorageHTTP.url(session.completeURL)
        var headers = ["Content-Type": StorageHTTP.octetStream]
        let body: HTTPBody
        switch variant {
        case .oss:
            // OSS 由服务端记录的分片自动合并，无需 XML。
            headers["Content-Length"] = "0"
            headers["x-oss-forbid-overwrite"] = "true"
            headers["x-oss-complete-all"] = "yes"
            body = .none
        case .cos:
            headers["x-cos-forbid-overwrite"] = "true"
            body = .data(Data(Self.completeXML(etags: etags).utf8))
        case .s3, .ks3, .obs:
            body = .data(Data(Self.completeXML(etags: etags).utf8))
        }
        _ = try await StorageHTTP.send(HTTPRequest(method: "POST", url: url, headers: headers, body: body), client: client)
        switch variant {
        case .s3, .ks3, .cos:
            try await client.completeS3Callback(policyType: variant.rawValue, sessionID: session.sessionID, secret: session.callbackSecret)
        case .obs, .oss:
            break
        }
    }

    /// `CompleteMultipartUpload` 请求体；PartNumber 从 1 开始，按序号升序。
    static func completeXML(etags: [Int: String]) -> String {
        let parts = etags.keys.sorted().map { index in
            "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(etags[index] ?? "")</ETag></Part>"
        }
        return "<CompleteMultipartUpload>" + parts.joined() + "</CompleteMultipartUpload>"
    }
}
