import CloudreveAPI
import CloudreveSync
import Foundation
import UniformTypeIdentifiers

/// 弹窗任务列表中的一行（由 `TransferRecord` 映射并附带实时速度）。
struct TransferRow: Identifiable, Equatable, Sendable {
    let id: String
    let driveID: String
    let kind: TransferKind
    let itemID: String?
    let name: String
    /// 父目录名；位于远端根目录时为 nil。
    let parentName: String?
    let totalBytes: Int64
    let doneBytes: Int64
    let state: TransferState
    let error: String?
    let startedAt: Date
    let finishedAt: Date?
    /// 字节/秒；仅进行中的任务有意义。
    let bytesPerSecond: Double
    /// 用于取系统文件图标的类型。
    let contentType: UTType

    init(record: TransferRecord, bytesPerSecond: Double) {
        id = record.id
        driveID = record.driveID
        kind = record.kind
        itemID = record.itemID
        name = record.name
        let parent = CloudreveURI(string: record.uri)?.parent
        parentName = parent.flatMap { $0.isRoot ? nil : $0.lastPathComponent }
        totalBytes = record.totalBytes
        doneBytes = record.doneBytes
        state = record.state
        error = record.error
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        self.bytesPerSecond = bytesPerSecond
        let ext = (record.name as NSString).pathExtension
        contentType = ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    /// 进度 0…1。
    var fraction: Double {
        guard totalBytes > 0 else { return state == .running ? 0 : 1 }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }
}
