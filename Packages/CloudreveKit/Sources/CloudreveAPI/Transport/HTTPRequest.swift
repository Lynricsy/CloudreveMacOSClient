import Foundation

/// 传输层请求：与 URLSession 解耦，便于在 Linux 用 MockTransport 测试。
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: HTTPBody

    public init(method: String, url: URL, headers: [String: String] = [:], body: HTTPBody = .none) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// 请求体的字节（`.file` 时读取文件，仅供测试断言使用）。
    public var bodyData: Data? {
        switch body {
        case .none: return nil
        case .data(let data): return data
        case .file(let url): return try? Data(contentsOf: url)
        }
    }

    /// 解析后的查询参数（已解码）。
    public var queryItems: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var result: [String: String] = [:]
        for item in items { result[item.name] = item.value ?? "" }
        return result
    }
}
