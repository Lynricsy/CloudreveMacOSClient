import Foundation

/// 用户容量（字节）。
public struct Capacity: Codable, Sendable, Equatable {
    public var total: Int64
    public var used: Int64

    public init(total: Int64, used: Int64) {
        self.total = total
        self.used = used
    }
}
