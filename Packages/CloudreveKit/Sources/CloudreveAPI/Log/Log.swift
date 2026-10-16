import Foundation
import Synchronization

/// 日志级别。
public enum LogLevel: String, Sendable, Comparable, CaseIterable {
    case debug, info, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// 包内统一日志出口。默认写 stderr；macOS 上由 `OSLogSink` 替换为 os.Logger。
public final class Log: Sendable {
    public typealias Sink = @Sendable (_ level: LogLevel, _ category: String, _ message: String) -> Void

    private struct Configuration {
        var minimum: LogLevel
        var sink: Sink
    }

    public static let shared = Log()

    private let configuration = Mutex(Configuration(minimum: .info, sink: Log.stderrSink))

    public init() {}

    public func configure(minimum: LogLevel, sink: @escaping Sink) {
        configuration.withLock { $0 = Configuration(minimum: minimum, sink: sink) }
    }

    public func debug(_ category: String, _ message: @autoclosure () -> String) {
        write(.debug, category, message)
    }

    public func info(_ category: String, _ message: @autoclosure () -> String) {
        write(.info, category, message)
    }

    public func error(_ category: String, _ message: @autoclosure () -> String) {
        write(.error, category, message)
    }

    private func write(_ level: LogLevel, _ category: String, _ message: () -> String) {
        let current = configuration.withLock { $0 }
        guard level >= current.minimum else { return }
        current.sink(level, category, message())
    }

    public static let stderrSink: Sink = { level, category, message in
        FileHandle.standardError.write(Data("[\(level.rawValue)] [\(category)] \(message)\n".utf8))
    }
}
