import Foundation

/// 一条 Server-Sent Event。
public struct SSEEvent: Sendable, Equatable {
    /// `event:` 字段；未指定时为 nil（规范默认 `message`）。
    public var name: String?
    /// 多行 `data:` 以 `\n` 拼接。
    public var data: String
    public var id: String?

    public init(name: String?, data: String, id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }
}
