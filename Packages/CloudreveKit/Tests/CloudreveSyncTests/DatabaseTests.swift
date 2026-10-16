import CloudreveAPI
import Foundation
import GRDB
import Testing
@testable import CloudreveSync

@Suite struct DatabaseTests {
    @Test func migrationIsIdempotent() throws {
        let db = try SyncDatabase.openInMemory()
        try Migrations.migrator.migrate(db)
        let applied = try db.read { try Migrations.migrator.appliedMigrations($0) }
        #expect(applied == ["v1"])
        let tables = try db.read { db in
            try ["drive", "item", "change_log", "transfer", "upload_session", "app_setting"].allSatisfy { try db.tableExists($0) }
        }
        #expect(tables)
    }

    @Test func fileDatabaseUsesWALAndCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ck-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nested/cloudreve.sqlite")
        let db = try SyncDatabase.open(at: url)
        let mode = try db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
        let foreignKeys = try db.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(foreignKeys == true)
        // 再次打开（迁移已应用）不报错
        _ = try SyncDatabase.open(at: url)
    }

    @Test func driveRecordRoundTripStoresPlainColumns() throws {
        let db = try DBFixtures.database()
        let loaded = try DriveStore(db: db).get(id: DBFixtures.driveID)
        #expect(loaded == DBFixtures.drive())
        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM drive") }
        #expect(row?["site_url"] == "https://drive.example.com")
        #expect(row?["remote_root_uri"] == "cloudreve://my")
        #expect(row?["client_id"] == "11111111-2222-3333-4444-555555555555")
        #expect(row?["ignore_patterns"] == #"["*.log"]"#)
        #expect(row?["status"] == "active")
        #expect(row?["created_at"] == 1_700_000_000.0)
    }

    @Test func driveStoreUpdates() throws {
        let clock = DatabaseTestClock()
        let db = try DBFixtures.database()
        let store = DriveStore(db: db, now: clock.provider)
        try store.updateStatus(id: DBFixtures.driveID, .eventPushLost)
        try store.updateCapacity(id: DBFixtures.driveID, total: 100, used: 40)
        try store.updateIgnorePatterns(id: DBFixtures.driveID, ["a*", "百分%_"])
        clock.advance(10)
        try store.updateLastReconcile(id: DBFixtures.driveID)
        let drive = try #require(try store.get(id: DBFixtures.driveID))
        #expect(drive.status == .eventPushLost)
        #expect(drive.capacityTotal == 100 && drive.capacityUsed == 40)
        #expect(drive.capacityUpdatedAt == DBFixtures.epoch)
        #expect(drive.ignorePatterns == ["a*", "百分%_"])
        #expect(drive.lastReconcileAt == DBFixtures.epoch.addingTimeInterval(10))
        #expect(try store.all().map(\.id) == [DBFixtures.driveID])
    }

    @Test func driveDeleteCascades() throws {
        let db = try DBFixtures.database(drives: ["d1", "d2"])
        let items = ItemStore(db: db)
        try items.upsert([DBFixtures.item("f1", path: "/a.txt", driveID: "d1"), DBFixtures.item("f1", path: "/a.txt", driveID: "d2")])
        let transfers = TransferStore(db: db)
        _ = try transfers.start(driveID: "d1", kind: .upload, itemID: "f1", name: "a.txt", uri: "cloudreve://my/a.txt", total: 1)
        _ = try transfers.start(driveID: "d2", kind: .upload, itemID: "f1", name: "a.txt", uri: "cloudreve://my/a.txt", total: 1)
        try ChangeLog(db: db).append(driveID: "d1", itemID: "f1", kind: .update)
        try GRDBUploadProgressStore(db: db, driveID: "d1").saveSession(UploadStoreFixtures.stored(uri: "cloudreve://my/a.txt"))

        try DriveStore(db: db).delete(id: "d1")

        let counts = try db.read { db in
            try ["item", "transfer", "change_log", "upload_session"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE drive_id = 'd1'") ?? -1
            }
        }
        #expect(counts == [0, 0, 0, 0])
        #expect(try items.get(driveID: "d2", id: "f1") != nil)
        #expect(try transfers.recent(driveID: "d2").count == 1)
        #expect(try DriveStore(db: db).all().map(\.id) == ["d2"])
    }

    @Test func anchorCodecRoundTrip() {
        for value: Int64 in [0, 1, 255, 256, 30000, Int64.max, -1] {
            let data = SyncAnchorCodec.encode(value)
            #expect(data.count == 8)
            #expect(SyncAnchorCodec.decode(data) == value)
        }
        #expect(SyncAnchorCodec.encode(258) == Data([0, 0, 0, 0, 0, 0, 1, 2]))
        #expect(SyncAnchorCodec.decode(Data([1, 2, 3])) == nil)
    }

    @Test func appSettings() throws {
        let settings = AppSettings(db: try SyncDatabase.openInMemory())
        #expect(try settings.get("x") == nil)
        #expect(try settings.bool("notify", default: true))
        #expect(settings.logLevel == .info)
        try settings.set("notify", "false")
        try settings.set(AppSettings.logLevelKey, "debug")
        try settings.set("x", "1")
        try settings.set("x", "2")
        #expect(try settings.bool("notify", default: true) == false)
        #expect(settings.logLevel == .debug)
        #expect(try settings.get("x") == "2")
    }
}
