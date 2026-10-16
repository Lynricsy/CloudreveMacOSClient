import Foundation

/// 增量 SSE 解析器：可以在任意字节边界切分输入（含 UTF-8 多字节字符中间）。
public struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var name: String?
    private var dataLines: [String] = []
    private var id: String?

    public init() {}

    /// 喂入一段字节，返回本次凑齐的事件。
    public mutating func feed(_ data: Data) -> [SSEEvent] {
        buffer.append(contentsOf: data)
        var events: [SSEEvent] = []
        var lineStart = 0
        while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            var lineEnd = newline
            if lineEnd > lineStart, buffer[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
            let line = String(decoding: buffer[lineStart..<lineEnd], as: UTF8.self)
            if let event = process(line: line) { events.append(event) }
            lineStart = newline + 1
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
