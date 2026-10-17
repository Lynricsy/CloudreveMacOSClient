import CloudreveAPI
import Foundation
import GRDB
import Testing
@testable import CloudreveSync

@Suite struct RemoteEventQueueTests {
    @Test func batchesInOrderPerDriveAndRemovesOnlyThroughSeq() throws {
        let db = try DBFixtures.database(drives: ["d1", "d2"])
        let queue = RemoteEventQueue(db: db)
        let first = FileEvent(type: .create, fileID: "a", from: "/a.txt")
        let second = FileEvent(type: .rename, fileID: "b", from: "/b.txt", to: "/c.txt")
        try queue.append(driveID: "d1", events: [first, second])
        try queue.append(driveID: "d2", events: [FileEvent(type: .delete, fileID: "x", from: "/x")])

        let batch = try #require(try queue.next(driveID: "d1", limit: 1))
        #expect(batch.events == [first])
        #expect(!batch.needsReconcile)

        // 取出不等于消费：未删除前再次取出得到同一批
        #expect(try queue.next(driveID: "d1", limit: 1) == batch)
        try queue.remove(driveID: "d1", throughSeq: batch.lastSeq)
        #expect(try queue.next(driveID: "d1", limit: 10)?.events == [second])
        #expect(try queue.next(driveID: "d2", limit: 10)?.events.map(\.fileID) == ["x"])
    }

    @Test func reconcileRequestMarksBatch() throws {
        let db = try DBFixtures.database()
        let queue = RemoteEventQueue(db: db)
        try queue.append(driveID: DBFixtures.driveID, events: [FileEvent(type: .modify, fileID: "m", from: "/m")])
        try queue.requestReconcile(driveID: DBFixtures.driveID)
        let batch = try #require(try queue.next(driveID: DBFixtures.driveID, limit: 10))
        #expect(batch.needsReconcile)
        try queue.remove(driveID: DBFixtures.driveID, throughSeq: batch.lastSeq)
        #expect(try queue.next(driveID: DBFixtures.driveID, limit: 10) == nil)
    }
}
