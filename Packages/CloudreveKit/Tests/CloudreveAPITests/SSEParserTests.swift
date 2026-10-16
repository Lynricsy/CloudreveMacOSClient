import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct SSEParserTests {
    @Test func splitAcrossChunks() {
        var parser = SSEParser()
        #expect(parser.feed(Data("event: ev".utf8)).isEmpty)
        let events = parser.feed(Data("ent\ndata: {\"a\":1}\n\n".utf8))
        #expect(events == [SSEEvent(name: "event", data: "{\"a\":1}")])
    }

    @Test func crlfMultilineDataAndComments() {
        var parser = SSEParser()
        let text = ": comment\r\nevent: event\r\ndata: line1\r\ndata: line2\r\nid: 7\r\n\r\n"
        #expect(parser.feed(Data(text.utf8)) == [SSEEvent(name: "event", data: "line1\nline2", id: "7")])
    }

    @Test func multipleEventsInOneFeedIncludingKeepAlive() {
        var parser = SSEParser()
        let text = "event: subscribed\ndata: {}\n\nevent: keep-alive\n\nevent: event\ndata: [1]\n\n"
        let events = parser.feed(Data(text.utf8))
        #expect(events.map(\.name) == ["subscribed", "keep-alive", "event"])
        #expect(events[1].data.isEmpty)
    }

    @Test func multibyteCharacterSplit() {
        var parser = SSEParser()
        let bytes = Array("data: 中文\n\n".utf8)
        #expect(parser.feed(Data(bytes[0..<7])).isEmpty)
        #expect(parser.feed(Data(bytes[7...])) == [SSEEvent(name: nil, data: "中文")])
    }

    @Test func fileEventsStreamParsesAndRejectsDisabledPush() async throws {
        let mock = MockTransport()
        await mock.streamRoute("GET", "/api/v4/file/events") { request in
            #expect(request.headers["Accept"] == "text/event-stream")
            #expect(request.headers["X-Cr-Client-Id"] != nil)
            return (HTTPResponseHead(status: 200, headers: ["Content-Type": "text/event-stream"]),
                    [Data("event: subscr".utf8), Data("ibed\ndata: {}\n\n".utf8)])
        }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        var names: [String?] = []
        for try await event in client.fileEvents(uri: .my("/")) { names.append(event.name) }
        #expect(names == ["subscribed"])

        let disabled = MockTransport()
        await disabled.route("GET", "/api/v4/file/events") { _ in .envelope(code: 40001, msg: "disabled") }
        let other = Fixtures.client(mock: disabled, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        await #expect(throws: CloudreveAPIError.server(code: 40001, message: "disabled", correlationID: nil)) {
            for try await _ in other.fileEvents(uri: .my("/")) {}
        }
    }
}
