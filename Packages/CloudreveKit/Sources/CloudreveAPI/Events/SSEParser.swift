import Foundation

/// 增量 SSE 解析器：可以在任意字节边界切分输入（含 UTF-8 多字节字符中间）。
/// 行结束符按标准接受 CR、LF、CRLF，CRLF 跨数据块拆开时仍视为一个行结束符。
public struct SSEParser: Sendable {
    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")

    private var buffer: [UInt8] = []
    /// 上一块以 CR 结束：本块开头的 LF 属于同一个 CRLF，需要跳过。
    private var pendingCR = false
    private var name: String?
    private var dataLines: [String] = []
    private var id: String?

    public init() {}

    /// 喂入一段字节，返回本次凑齐的事件。
    public mutating func feed(_ data: Data) -> [SSEEvent] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)
        var events: [SSEEvent] = []
        var lineStart = 0
        if pendingCR {
            pendingCR = false
            if buffer.first == Self.lf { lineStart = 1 }
        }
        while let lineEnd = buffer[lineStart...].firstIndex(where: { $0 == Self.lf || $0 == Self.cr }) {
            let line = String(decoding: buffer[lineStart..<lineEnd], as: UTF8.self)
            if let event = process(line: line) { events.append(event) }
            lineStart = lineEnd + 1
            if buffer[lineEnd] == Self.cr {
                if lineStart == buffer.count {
                    pendingCR = true
                } else if buffer[lineStart] == Self.lf {
                    lineStart += 1
                }
            }
        }
        buffer.removeFirst(lineStart)
        return events
    }

    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": dataLines.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            name = nil
            dataLines = []
        }
        guard name != nil || !dataLines.isEmpty else { return nil }
        return SSEEvent(name: name, data: dataLines.joined(separator: "\n"), id: id)
    }
}
