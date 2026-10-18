import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct CredentialStoreTests {
    private let id = Fixtures.driveID

    @Test func updateWritesNonNilAndReturnsFinalValue() throws {
        let original = Fixtures.credentials(access: "a")
        let store = InMemoryCredentialStore([id: original])
        let next = Fixtures.credentials(access: "b")
        let seen = Recorder<Credentials?>()
        let result = try store.update(driveID: id) { current in
            seen.append(current)
            return next
        }
        #expect(seen.values == [original])
        #expect(result == next)
        #expect(try store.load(driveID: id) == next)
    }

    @Test func updateReturningNilKeepsCurrentValue() throws {
        let original = Fixtures.credentials(access: "a")
        let store = InMemoryCredentialStore([id: original])
        #expect(try store.update(driveID: id) { _ in nil } == original)
        #expect(try store.load(driveID: id) == original)

        let empty = InMemoryCredentialStore()
        #expect(try empty.update(driveID: id) { current in current } == nil)
        #expect(try empty.load(driveID: id) == nil)
    }

    @Test func throwingTransformDoesNotWrite() throws {
        let original = Fixtures.credentials(access: "a")
        let store = InMemoryCredentialStore([id: original])
        #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try store.update(driveID: id) { _ in throw CloudreveAPIError.credentialInvalid }
        }
        #expect(try store.load(driveID: id) == original)
    }

    /// 读改写在锁内完成：并发 update 不丢失任何一次修改。
    @Test func concurrentUpdatesAreNotLost() async throws {
        let store = InMemoryCredentialStore([id: Fixtures.credentials(access: "")])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    _ = try? store.update(driveID: id) { current in
                        guard var next = current else { return nil }
                        next.accessToken += "x"
                        return next
                    }
                }
            }
        }
        #expect(try store.load(driveID: id)?.accessToken.count == 200)
    }

    /// transform 执行期间另一线程的删除必须等 update 结束才生效，不能插在读与写之间。
    @Test func deleteDuringTransformWaitsForUpdate() throws {
        let store = InMemoryCredentialStore([id: Fixtures.credentials(access: "a")])
        let order = Recorder<String>()
        let deleted = DispatchSemaphore(value: 0)
        _ = try store.update(driveID: id) { current in
            Thread.detachNewThread {
                try? store.delete(driveID: id)
                order.append("delete")
                deleted.signal()
            }
            Thread.sleep(forTimeInterval: 0.05)
            order.append("transform")
            return current.map { var next = $0; next.accessToken = "b"; return next }
        }
        deleted.wait()
        #expect(order.values == ["transform", "delete"])
        #expect(try store.load(driveID: id) == nil)
    }
}
