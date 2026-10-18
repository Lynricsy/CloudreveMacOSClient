import CloudreveAPI
import Foundation
import os

/// 把包内 `Log` 输出接到统一日志系统（`log stream --predicate 'subsystem == "plus.ling.cloudreve"'`）。
///
/// 消息在接收器处已是拼好的字符串，无法区分静态与动态部分。为保留排障所需的路径、状态码等信息，
/// 消息仍以 `.public` 写入，但先经 `LogRedactor` 抹掉令牌、签名、回调密钥等凭据类内容。
enum OSLogSink {
    static let subsystem = "plus.ling.cloudreve"

    static func install(minimum: LogLevel) {
        Log.shared.configure(minimum: minimum) { level, category, message in
            let logger = Logger(subsystem: subsystem, category: category)
            let redacted = LogRedactor.redact(message)
            switch level {
            case .debug: logger.debug("\(redacted, privacy: .public)")
            case .info: logger.info("\(redacted, privacy: .public)")
            case .error: logger.error("\(redacted, privacy: .public)")
            }
        }
    }
}

/// 日志脱敏：替换凭据类内容，其余原样保留。
enum LogRedactor {
    static let placeholder = "<redacted>"

    /// 名称含这些词的参数 / 字段视为凭据（大小写不敏感），如 access_token、X-Amz-Signature、X-Amz-Credential、tempauth。
    ///
    /// 日志可能带未截断的服务端响应体，模式须保持线性：名称只从单词边界起匹配（后行断言），关键词用前瞻在
    /// 有界长度内查找，名称本身用有界占有量词一次吞下，不在重叠字符集之间回溯。超过 128 字符的名称不视为参数名。
    private static let secretKey =
        #"(?<![\w.-])(?=[\w.-]{0,64}?(?:token|secret|passw(?:or)?d|sign(?:ature)?|credential|auth|key))[\w.-]{1,128}+"#

    private static let rules: [(NSRegularExpression, String)] = [
        // 上传完成回调 /callback/<策略>/<会话>/<密钥>：密钥即回调凭据
        (#"(/callback/[^/\s]{1,256}+/[^/\s]{1,256}+/)[^/\s?#"']++"#, "$1\(placeholder)"),
        // Authorization: Bearer <token>
        (#"(?i)\b(bearer\s++)[A-Za-z0-9._~+/=-]++"#, "$1\(placeholder)"),
        // JWT（access / refresh token）
        (#"\beyJ[A-Za-z0-9_-]{4,}+\.[A-Za-z0-9_-]{4,}+\.[A-Za-z0-9_-]*+"#, placeholder),
        // URL 查询 / 表单参数：token=…、sign=…、X-Amz-Signature=…
        (#"(?i)(\#(secretKey)=)[^&\s"'#]++"#, "$1\(placeholder)"),
        // JSON 字段："access_token": "…"
        (#"(?i)("\#(secretKey)"\s*+:\s*+)"[^"]*+""#, "$1\"\(placeholder)\"")
    ].map { pattern, template in
        // 模式为编译期常量，构造失败属于编程错误
        // swiftlint:disable:next force_try
        (try! NSRegularExpression(pattern: pattern), template)
    }

    static func redact(_ message: String) -> String {
        rules.reduce(message) { text, rule in
            let range = NSRange(text.startIndex..., in: text)
            return rule.0.stringByReplacingMatches(in: text, range: range, withTemplate: rule.1)
        }
    }
}
