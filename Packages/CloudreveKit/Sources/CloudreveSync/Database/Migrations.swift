import GRDB

/// 数据库迁移。已发布的迁移不得修改，只能追加新版本。
public enum Migrations {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: v2)
        }
        return migrator
    }

    private static let v1 = """
        CREATE TABLE drive (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            site_url TEXT NOT NULL,
            remote_root_uri TEXT NOT NULL,
            root_file_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            user_email TEXT,
            site_title TEXT,
            client_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            ignore_patterns TEXT NOT NULL DEFAULT '[]',
            capacity_total INTEGER NOT NULL DEFAULT 0,
            capacity_used INTEGER NOT NULL DEFAULT 0,
            capacity_updated_at DOUBLE,
            last_reconcile_at DOUBLE,
            created_at DOUBLE NOT NULL
        );

        CREATE TABLE item (
            drive_id TEXT NOT NULL REFERENCES drive(id) ON DELETE CASCADE,
            id TEXT NOT NULL,
            parent_id TEXT,
            name TEXT NOT NULL,
            is_folder BOOLEAN NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            entity_id TEXT NOT NULL DEFAULT '',
            uri TEXT NOT NULL,
            created_at DOUBLE NOT NULL,
            updated_at DOUBLE NOT NULL,
            enumerated_at DOUBLE,
            PRIMARY KEY (drive_id, id)
        );
        CREATE INDEX item_parent ON item(drive_id, parent_id);
        CREATE UNIQUE INDEX item_uri ON item(drive_id, uri);

        CREATE TABLE change_log (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            drive_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            created_at DOUBLE NOT NULL
        );
        CREATE INDEX change_log_drive_seq ON change_log(drive_id, seq);

        CREATE TABLE transfer (
            id TEXT PRIMARY KEY NOT NULL,
            drive_id TEXT NOT NULL REFERENCES drive(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            item_id TEXT,
            name TEXT NOT NULL,
            uri TEXT NOT NULL,
            total_bytes INTEGER NOT NULL,
            done_bytes INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL,
            error TEXT,
            started_at DOUBLE NOT NULL,
            finished_at DOUBLE,
            notified BOOLEAN NOT NULL DEFAULT 0
        );
        CREATE INDEX transfer_drive_state ON transfer(drive_id, state);
        CREATE INDEX transfer_finished ON transfer(finished_at);

        CREATE TABLE upload_session (
            drive_id TEXT NOT NULL,
            uri TEXT NOT NULL,
            size INTEGER NOT NULL,
            policy_type TEXT NOT NULL,
            session_json TEXT NOT NULL,
            chunks_json TEXT NOT NULL,
            created_at DOUBLE NOT NULL,
            PRIMARY KEY (drive_id, uri)
        );

        CREATE TABLE app_setting (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """

    /// 远端变更队列：App 的推送订阅写入，扩展在系统请求内取出应用、成功后删除。
    /// `kind = 'event'` 时 `event_json` 为 `FileEvent` JSON；`kind = 'reconcile'` 表示需要全量兜底。
    private static let v2 = """
        CREATE TABLE remote_event (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            drive_id TEXT NOT NULL REFERENCES drive(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            event_json TEXT,
            created_at DOUBLE NOT NULL
        );
        CREATE INDEX remote_event_drive_seq ON remote_event(drive_id, seq);
        """
}
