import Foundation

/// 计算传输速度用的上一次采样（按 transfer id 缓存）。
struct TransferSample: Equatable, Sendable {
    let bytes: Int64
    let time: Date
    let bytesPerSecond: Double
}
