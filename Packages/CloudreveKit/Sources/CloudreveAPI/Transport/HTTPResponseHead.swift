import Foundation

/// 流式响应的头部。`headers` 的键统一为小写。
public struct HTTPResponseHead: Sendable {
    public var status: Int
    public var headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
