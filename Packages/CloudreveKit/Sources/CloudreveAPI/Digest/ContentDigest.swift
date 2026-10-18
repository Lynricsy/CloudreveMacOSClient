#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// 内容 SHA-256：统一用小写十六进制表示（与 OpenCloudreve `entities.sha256` 一致）。
public enum ContentDigest {
    /// 摘要的小写十六进制文本。
    public static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 规范化服务端给出的摘要：64 位十六进制（大小写不限）转为小写，其余返回 nil。
    public static func normalizedSHA256(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.utf8.count == 64, lower.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        return lower
    }

    /// 流式读取整个文件计算 SHA-256，内存占用与文件大小无关。每读一块检查一次任务取消，取消时抛 `CancellationError`。
    public static func sha256(of fileURL: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        var hasher = SHA256()
        var done = false
        while !done {
            try Task.checkCancellation()
            try ChunkStaging.withBufferPool {
                guard let data = try input.read(upToCount: ChunkStaging.bufferSize), !data.isEmpty else {
                    done = true
                    return
                }
                hasher.update(data: data)
            }
        }
        return hex(hasher.finalize())
    }
}
