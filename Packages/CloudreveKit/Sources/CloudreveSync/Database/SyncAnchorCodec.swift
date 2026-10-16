import Foundation

/// File Provider sync anchor ↔ `change_log.seq`：8 字节大端 Int64。
public enum SyncAnchorCodec {
    public static func encode(_ seq: Int64) -> Data {
        withUnsafeBytes(of: seq.bigEndian) { Data($0) }
    }

    /// 长度不是 8 字节时返回 nil（视为过期 anchor）。
    public static func decode(_ data: Data) -> Int64? {
        guard data.count == 8 else { return nil }
        let value = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(bitPattern: value)
    }
}
