import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// S3 兼容系策略（s3/ks3/cos/obs/oss）：分片 PUT 到预签名地址，取 etag；合并时向 `completeURL` 提交合并请求，
/// 再按厂商回调 Cloudreve（OSS 由存储自行回调）。
public struct S3FamilyStrategy: ChunkStrategy {
    /// 具体厂商，`rawValue` 即策略类型与回调路径段。
    public enum Variant: String, Sendable, CaseIterable {
        case s3, ks3, cos, obs, oss
    }

    public let variant: Variant

    public init(variant: Variant) {
        self.variant = variant
    }

    public func upload(chunk: UploadChunk, body: HTTPBody, session: UploadSession, client: CloudreveClient) async throws -> String? {
        let url = try StorageHTTP.uploadURL(session, index: chunk.index)
        let request = HTTPRequest(method: "PUT", url: url, headers: ["Content-Type": StorageHTTP.octetStream], body: body)
        let response = try await StorageHTTP.send(request, client: client)
        return StorageHTTP.etag(response)
    }

    public func merge(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {
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
        let response = try await StorageHTTP.send(HTTPRequest(method: "POST", url: url, headers: headers, body: body), client: client)
        // CompleteMultipartUpload 可能先发出 200 响应头，再在响应体里返回 <Error>：必须解析响应体确认合并成功。
        if let error = S3ErrorDocument.parse(response.body) {
            throw CloudreveAPIError.http(status: error.equivalentStatus, body: String(decoding: response.body, as: UTF8.self))
        }
    }

    public func commit(session: UploadSession, client: CloudreveClient) async throws {
        switch variant {
        case .s3, .ks3, .cos:
            try await client.completeS3Callback(policyType: variant.rawValue, sessionID: session.sessionID, secret: session.callbackSecret)
        case .obs:
            try await client.completeOBSCallback(sessionID: session.sessionID, secret: session.callbackSecret)
        case .oss:
            break
        }
    }

    /// 重发合并得到 `NoSuchUpload`：上传 ID 已被此前未确认的合并消耗。
    public func indicatesEarlierMerge(_ error: any Error) -> Bool {
        guard case let .http(status, body)? = error as? CloudreveAPIError, status == 404 else { return false }
        return S3ErrorDocument.parse(Data(body.utf8))?.code == "NoSuchUpload"
    }

    /// `CompleteMultipartUpload` 请求体；PartNumber 从 1 开始，按序号升序。
    static func completeXML(etags: [Int: String]) -> String {
        let parts = etags.keys.sorted().map { index in
            "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(etags[index] ?? "")</ETag></Part>"
        }
        return "<CompleteMultipartUpload>" + parts.joined() + "</CompleteMultipartUpload>"
    }
}

/// S3 系错误响应体 `<Error><Code>…</Code><Message>…</Message></Error>`。
struct S3ErrorDocument: Equatable {
    var code: String

    /// 合并请求的确定性失败（重试无意义）；其余（InternalError、SlowDown 等）按 5xx 处理以便保留会话重试。
    private static let permanentCodes: Set<String> = [
        "InvalidPart", "InvalidPartOrder", "EntityTooSmall", "EntityTooLarge", "InvalidArgument", "InvalidRequest",
        "MalformedXML", "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "PreconditionFailed",
        "FileAlreadyExists"
    ]

    /// 内嵌错误对应的 HTTP 状态，供 `Uploader.isRetryable` 判断。
    var equivalentStatus: Int {
        if code == "NoSuchUpload" { return 404 }
        return Self.permanentCodes.contains(code) ? 400 : 500
    }

    /// 根元素是 `Error` 时返回其错误码；其他文档（含空响应体）返回 nil。
    static func parse(_ body: Data) -> S3ErrorDocument? {
        guard !body.isEmpty else { return nil }
        let reader = ErrorXMLReader()
        let parser = XMLParser(data: body)
        parser.delegate = reader
        _ = parser.parse()
        guard reader.root == "Error" else { return nil }
        return S3ErrorDocument(code: reader.code)
    }
}

/// 读取根元素名及其直接子元素 Code 的文本。
private final class ErrorXMLReader: NSObject, XMLParserDelegate {
    var root: String?
    var code = ""
    private var path: [String] = []
    private var text = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if path.isEmpty { root = elementName }
        path.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if path.count == 2, elementName == "Code" {
            code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        path.removeLast()
        text = ""
    }
}
