import Foundation

/// Cloudreve（Go）时间格式：RFC3339，可带任意位小数秒（RFC3339Nano）。
public enum CloudreveDate {
    /// 解析 RFC3339 字符串。先去掉小数秒按整秒解析，再把小数部分加回去，
    /// 以兼容 Go 输出的 9 位纳秒精度。
    public static func parse(_ string: String) -> Date? {
        var text = string
        var fraction = 0.0
        if let tIndex = text.firstIndex(of: "T"), let dot = text[tIndex...].firstIndex(of: ".") {
            let digitsEnd = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<digitsEnd]
            fraction = Double("0.\(digits)") ?? 0
            text.removeSubrange(dot..<digitsEnd)
        }
        guard let whole = try? Date(text, strategy: .iso8601) else { return nil }
        return whole.addingTimeInterval(fraction)
    }

    /// 输出 RFC3339（毫秒精度），供测试和 Mock 使用。
    public static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    /// 使用 Cloudreve 日期策略的解码器。
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期：\(text)")
            }
            return date
        }
        return decoder
    }
}
