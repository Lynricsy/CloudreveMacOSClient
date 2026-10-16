import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct TokenManagerTests {
    @Test func concurrentAccessTokenRefreshesOnce() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        let refreshes = Counter()
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in
            _ = await refreshes.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Fixtures.credentials(access: "fresh")
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await manager.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "fresh", count: 10))
        #expect(await refreshes.current == 1)
    }

    @Test func recoverUsesTokenRefreshedByOtherProcess() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(access: "other-process")])
        let refreshes = Counter()
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in
            _ = await refreshes.increment()
            return Fixtures.credentials(access: "fresh")
        }
        let token = try await manager.recover(afterUnauthorizedWith: "stale")
        #expect(token == "other-process")
        #expect(await refreshes.current == 0)
    }

    @Test func expiredRefreshTokenIsInvalid() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: -10, refreshIn: -10)])
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in Fixtures.credentials(access: "never") }
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await manager.accessToken()
        }
    }

    @Test func missingCredentialsIsInvalid() async throws {
        let manager = TokenManager(driveID: "none", store: InMemoryCredentialStore()) { _ in Fixtures.credentials() }
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await manager.accessToken()
        }
    }
}
