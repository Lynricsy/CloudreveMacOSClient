import CloudreveAPI
import Foundation
import Testing
@testable import CloudreveSync

/// Verification 10：忽略规则只匹配文件名。
@Suite struct IgnoreRulesTests {
    @Test func defaultsMatchOfficeAndSystemFiles() {
        let rules = IgnoreRules(userPatterns: [])
        #expect(rules.matches(name: "~$报告.docx"))
        #expect(rules.matches(name: "~WRL0001.tmp"))
        #expect(rules.matches(name: ".~lock.表格.ods#"))
        #expect(rules.matches(name: ".DS_Store"))
        #expect(!rules.matches(name: "报告.docx"))
        #expect(!rules.matches(name: "a.tmp"))
    }

    @Test func userPatternsSkipBlankAndComments() {
        let rules = IgnoreRules(userPatterns: ["*.tmp", "", "   ", "# 注释", "#*"])
        #expect(rules.patterns == IgnoreRules.defaults + ["*.tmp"])
        #expect(rules.matches(name: "a.tmp"))
        #expect(!rules.matches(name: "a.tmpx"))
        #expect(!rules.matches(name: "#x"))
    }

    @Test func patternsDoNotMatchAcrossPath() {
        let rules = IgnoreRules(userPatterns: ["build"])
        #expect(rules.matches(name: "build"))
        #expect(!rules.matches(name: "builds"))
    }
}

@Suite struct ConflictNamingTests {
    @Test func formatsWithFixedTimeZone() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        #expect(ConflictNaming.conflictCopyName(for: "a b.txt", at: date, timeZone: utc) == "__conflict__20231114221320_a b.txt")
        #expect(ConflictNaming.conflictCopyName(for: "报告.docx", at: date, timeZone: shanghai) == "__conflict__20231115061320_报告.docx")
    }
}

@Suite struct MIMETypesTests {
    @Test func guessesByExtension() {
        #expect(MIMETypes.guess(fileName: "a.TXT") == "text/plain")
        #expect(MIMETypes.guess(fileName: "archive.tar.gz") == "application/gzip")
        #expect(MIMETypes.guess(fileName: ".bashrc") == MIMETypes.fallback)
        #expect(MIMETypes.guess(fileName: "noext") == MIMETypes.fallback)
        #expect(MIMETypes.guess(fileName: "x.unknown") == MIMETypes.fallback)
    }
}

@Suite struct SyncErrorMapperTests {
    /// 暂时性故障（传输错误、HTTP 408/429/5xx、URLError）一律映射为 serverUnreachable，系统会稍后重试。
    @Test func transientFailuresMapToServerUnreachable() {
        let transient: [any Error] = [
            CloudreveAPIError.transport("reset"), CloudreveAPIError.http(status: 429, body: ""),
            CloudreveAPIError.http(status: 408, body: ""), CloudreveAPIError.http(status: 503, body: ""),
            URLError(.timedOut)
        ]
        for error in transient {
            #expect(SyncErrorMapper.map(error) as? SyncError == .serverUnreachable, "\(error)")
        }
        #expect(SyncErrorMapper.map(CloudreveAPIError.http(status: 403, body: "")) as? SyncError != .serverUnreachable)
    }

    /// 非协议层错误（本地文件、钥匙串等）原样返回，由扩展按域决定；业务错误码照常映射。
    @Test func nonProtocolErrorsPassThrough() {
        let local = CocoaError(.fileWriteOutOfSpace)
        #expect(SyncErrorMapper.map(local) as? CocoaError == local)
        #expect(SyncErrorMapper.map(CloudreveAPIError.server(code: 40004, message: "", correlationID: nil)) as? SyncError
            == .filenameCollision(existing: nil))
    }
}

@Suite struct ItemVersionTests {
    /// metadata 分量不超过 SDK 上限 128 字节：长文件名也只得到 64 字节的 SHA-256 十六进制串，且随名称变化。
    @Test func metadataVersionIsBoundedHash() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = String(repeating: "长", count: 255)
        let item = SyncItem(
            id: "f", parentID: "p", name: name, isFolder: false, size: 1, entityID: "E1", createdAt: date, updatedAt: date,
            uri: .my("/\(name)")
        )
        let metadata = item.version.metadata
        #expect(metadata.utf8.count == 64)
        #expect(metadata.allSatisfy { $0.isHexDigit })
        #expect(item.version.content == "E1")
        var renamed = item
        renamed.name = "other"
        #expect(renamed.version.metadata != metadata)
    }
}
