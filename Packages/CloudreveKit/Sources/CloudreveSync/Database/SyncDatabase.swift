import Foundation
import GRDB

/// 共享 SQLite 数据库的打开入口。App 与扩展进程打开同一文件（WAL），均会先执行迁移。
public enum SyncDatabase {
    /// 打开文件数据库（`DatabasePool`，WAL 模式）。父目录不存在时自动创建。
    public static func open(at url: URL) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // DatabasePool 默认启用 WAL；两个进程并发写时最多等待 5 秒。
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        try Migrations.migrator.migrate(pool)
        return pool
    }

    /// 内存数据库（`DatabaseQueue`），用于测试。
    public static func openInMemory() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue(configuration: configuration())
        try Migrations.migrator.migrate(queue)
        return queue
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        return config
    }
}
