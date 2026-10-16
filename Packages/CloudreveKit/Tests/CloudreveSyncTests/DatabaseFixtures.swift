import CloudreveAPI
import Foundation
import GRDB
import Synchronization
@testable import CloudreveSync

/// 可手动推进的测试时钟。
final class DatabaseTestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var provider: @Sendable () -> Date { { self.now } }
}

enum DBFixtures {
    static let driveID = "drive-1"
    static let rootID = "root"
    static let rootURI = CloudreveURI.my("/")
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func drive(id: String = driveID) -> DriveRecord {
        DriveRecord(
            id: id,
            name: "我的云盘",
            siteURL: URL(string: "https://drive.example.com")!,
            remoteRootURI: rootURI,
            rootFileID: rootID,
            userID: "u1",
            clientID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            ignorePatterns: ["*.log"],
            createdAt: epoch
        )
    }

    static func root(driveID: String = driveID) -> ItemRecord {
        ItemRecord(driveID: driveID, id: rootID, parentID: nil, name: "", isFolder: true, uri: rootURI, createdAt: epoch, updatedAt: epoch)
    }

    static func item(
        _ id: String, path: String, parent: String = rootID, folder: Bool = false, entity: String = "e1", driveID: String = driveID
    ) -> ItemRecord {
        let uri = CloudreveURI.my(path)
        return ItemRecord(
            driveID: driveID, id: id, parentID: parent, name: uri.lastPathComponent, isFolder: folder, size: folder ? 0 : 10,
            entityID: folder ? "" : entity, uri: uri, createdAt: epoch, updatedAt: epoch
        )
    }

    /// 内存库 + 一个云盘及其根目录。
    static func database(drives: [String] = [driveID]) throws -> any DatabaseWriter {
        let db = try SyncDatabase.openInMemory()
        let store = DriveStore(db: db)
        for id in drives {
            try store.insert(drive(id: id), rootItem: root(driveID: id))
        }
        return db
    }
}
