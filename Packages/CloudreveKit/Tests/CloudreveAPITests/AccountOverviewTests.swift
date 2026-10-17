import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct AccountOverviewTests {
    private static let rootURI = CloudreveURI.my("/mount")

    private static let timestamps = #""created_at":"2026-10-17T20:00:00+08:00","updated_at":"2026-10-17T20:00:00+08:00""#

    private static func fileJSON(_ id: String) -> String {
        #"{"type":0,"id":"\#(id)","name":"\#(id)",\#(timestamps),"size":1}"#
    }

    private static func shareJSON(_ id: String, visited: Int, expired: Bool = false) -> String {
        #"{"id":"\#(id)","name":"\#(id)","visited":\#(visited),"expired":\#(expired)}"#
    }

    private static func page(_ items: [String], key: String, next: String?, extra: String = "") -> HTTPResponse {
        let token = next.map { #","next_token":"\#($0)""# } ?? ""
        let pagination = #""pagination":{"page":0,"page_size":100,"is_cursor":true\#(token)}"#
        return .envelope(dataJSON: #"{"\#(key)":[\#(items.joined(separator: ","))],\#(pagination)\#(extra)}"#)
    }

    private static func query(_ request: HTTPRequest, _ name: String) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// 除分享外的固定路由：用户（含用户组）、版本、根目录（含存储策略）、回收站分两页共 3 项。
    private static func routeCommon(_ mock: MockTransport) async {
        await mock.route("GET", "/api/v4/user/me") { _ in
            let group = #""group":{"id":"g","name":"Admin","trash_retention":604800}"#
            return .envelope(dataJSON: #"{"id":"u1","email":"a@b.c","created_at":"2026-10-17T20:25:21+08:00",\#(group)}"#)
        }
        await mock.route("GET", "/api/v4/site/ping") { _ in .envelope(dataJSON: #""4.19.1""#) }
        await mock.route("GET", "/api/v4/file") { request in
            switch (query(request, "uri"), query(request, "next_page_token")) {
            case ("cloudreve://trash", nil):
                return page([fileJSON("t1"), fileJSON("t2")], key: "files", next: "p2")
            case ("cloudreve://trash", "p2"):
                return page([fileJSON("t3")], key: "files", next: nil)
            default:
                #expect(query(request, "uri") == rootURI.description)
                return page([], key: "files", next: nil, extra: #","storage_policy":{"id":"p","name":"本地","type":"local"}"#)
            }
        }
    }

    @Test func aggregatesAcrossPages() async throws {
        let mock = MockTransport()
        await Self.routeCommon(mock)
        await mock.route("GET", "/api/v4/share") { request in
            if Self.query(request, "next_page_token") == "s2" {
                return Self.page([Self.shareJSON("c", visited: 5, expired: true)], key: "shares", next: nil)
            }
            return Self.page([Self.shareJSON("a", visited: 2), Self.shareJSON("b", visited: 3)], key: "shares", next: "s2")
        }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))

        let overview = try await client.accountOverview(rootURI: Self.rootURI)

        #expect(overview.shares == ShareSummary(count: PagedCount(count: 3), visits: 10, expired: 1))
        #expect(overview.trash == PagedCount(count: 3))
        #expect(overview.user.group == UserGroup(id: "g", name: "Admin", trashRetention: 604800))
        #expect(overview.user.createdAt != nil)
        #expect(overview.storagePolicy?.name == "本地")
        #expect(overview.serverVersion == "4.19.1")
    }

    @Test func stopsAtPageCapAndMarksTruncated() async throws {
        let mock = MockTransport()
        await Self.routeCommon(mock)
        await mock.route("GET", "/api/v4/share") { _ in
            Self.page([Self.shareJSON("x", visited: 1)], key: "shares", next: "more")
        }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))

        let overview = try await client.accountOverview(rootURI: Self.rootURI)

        #expect(overview.shares.count == PagedCount(count: CloudreveClient.shareMaxPages, isTruncated: true))
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/share").count == CloudreveClient.shareMaxPages)
    }

    @Test func emptyShareListDecodesNull() async throws {
        let mock = MockTransport()
        await mock.route("GET", "/api/v4/share") { _ in
            .envelope(dataJSON: #"{"shares":null,"pagination":{"page":0,"page_size":100,"is_cursor":true}}"#)
        }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        #expect(try await client.listShares().shares.isEmpty)
    }
}
