import CloudreveAPI
import Foundation
import os

/// 把包内 `Log` 输出接到统一日志系统（`log stream --predicate 'subsystem == "plus.ling.cloudreve"'`）。
enum OSLogSink {
    static let subsystem = "plus.ling.cloudreve"

    static func install(minimum: LogLevel) {
        Log.shared.configure(minimum: minimum) { level, category, message in
            let logger = Logger(subsystem: subsystem, category: category)
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
        }
    }
}
