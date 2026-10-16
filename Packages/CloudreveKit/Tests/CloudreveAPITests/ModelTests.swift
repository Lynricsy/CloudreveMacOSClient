import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct ModelTests {
    @Test(arguments: ["报告 2024.docx", "a b", "c#d", "e?f", "100%", "x+y"])
    func uriRoundTrip(name: String) throws {
        let uri = CloudreveURI.my("/目录").appending(name)
        let parsed = try #require(CloudreveURI(string: uri.description))
        #expect(parsed == uri)
        #expect(parsed.lastPathComponent == name)
        #expect(!uri.description.contains(" "))
    }

    @Test func uriRootAndRelative() throws {
        let root = CloudreveURI.my("/a")
        #expect(CloudreveURI.my("").description == "cloudreve://my")
        #expect(CloudreveURI(string: "cloudreve://my/")?.isRoot == true)
        #expect(CloudreveURI.my("/a/b/c.txt").relativePath(under: root) == "/b/c.txt")
        #expect(root.relativePath(under: root) == "/")
        #expect(CloudreveURI.my("/ab").relativePath(under: root) == nil)
        #expect(CloudreveURI.join(root: root, relative: "/b/c.txt") == .my("/a/b/c.txt"))
        #expect(CloudreveURI.my("/a/b").parent == root)
        #expect(CloudreveURI(string: "cloudreve://share/x") == nil)
    }

    @Test func credentialsFromOAuth() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oauth = OAuthTokenResponse(accessToken: "a", expiresIn: 3600, refreshTokenExpiresIn: 7200, refreshToken: "r")
        let credentials = try Credentials(oauth: oauth, now: now)
        #expect(credentials.accessExpires == now.addingTimeInterval(3600))
        #expect(credentials.refreshExpires == now.addingTimeInterval(7200))
        let defaulted = try Credentials(
            oauth: OAuthTokenResponse(accessToken: "a", expiresIn: 60, refreshToken: "r"), now: now
        )
        #expect(defaulted.refreshExpires == now.addingTimeInterval(7_776_000))
        #expect(throws: CloudreveAPIError.missingRefreshToken) {
            _ = try Credentials(oauth: OAuthTokenResponse(accessToken: "a", expiresIn: 60, refreshToken: nil), now: now)
        }
    }

    @Test func fileEventDecodesSingleAndList() {
        let single = Data(#"{"type":"rename","file_id":"f1","from":"/a","to":"/b"}"#.utf8)
        #expect(FileEvent.decodeList(single) == [FileEvent(type: .rename, fileID: "f1", from: "/a", to: "/b")])
        let list = Data(#"[{"type":"create","file_id":"f1","from":"/a"},{"type":"delete","file_id":"f2","from":"/c"}]"#.utf8)
        #expect(FileEvent.decodeList(list).map(\.fileID) == ["f1", "f2"])
        #expect(FileEvent.decodeList(Data("garbage".utf8)).isEmpty)
    }

    @Test func dateParsesNanoseconds() throws {
        let date = try #require(CloudreveDate.parse("2024-05-01T12:00:00.5+08:00"))
        #expect(date.timeIntervalSince1970 == 1_714_536_000.5)
        #expect(CloudreveDate.parse("2024-05-01T04:00:00Z")?.timeIntervalSince1970 == 1_714_536_000)
        let roundTrip = try #require(CloudreveDate.parse(CloudreveDate.format(date)))
        #expect(abs(roundTrip.timeIntervalSince(date)) < 0.001)
    }
}
