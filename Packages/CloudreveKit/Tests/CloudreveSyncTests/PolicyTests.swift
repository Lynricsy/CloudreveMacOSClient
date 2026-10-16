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
