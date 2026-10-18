#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// 分片暂存：把文件中某个分片范围写入独立的临时文件并计算其 SHA-256，供 URLSession 从磁盘流式上传。
///
/// 复制与摘要均按固定大小缓冲进行，内存占用与文件/分片大小无关；摘要针对暂存后的字节，
/// 即实际上传的内容，续传复用会话前用它与本地文件比对。
enum ChunkStaging {
    static let bufferSize = 1 << 20

    struct Staged: Sendable {
        let url: URL
        let digest: String
    }

    /// 暂存 `chunk`。分片覆盖整个文件时用 `copyItem`（APFS 上为写时复制克隆，不额外占用磁盘），否则按范围流式复制。
    /// 文件已被截短时抛 `.transport("short read")`。
    static func stage(_ chunk: UploadChunk, of fileURL: URL, in directory: URL) throws -> Staged {
        let destination = directory.appendingPathComponent("chunk-\(UUID().uuidString)")
        do {
            if chunk.offset == 0, try size(of: fileURL) == chunk.length {
                try FileManager.default.copyItem(at: fileURL, to: destination)
                guard try size(of: destination) == chunk.length else { throw shortRead }
                let digest = try digest(of: UploadChunk(index: chunk.index, offset: 0, length: chunk.length), in: destination)
                return Staged(url: destination, digest: digest)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let digest = try transfer(chunk, from: input, to: output)
            return Staged(url: destination, digest: digest)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// 文件中 `chunk` 范围内容的 SHA-256（小写十六进制）。
    static func digest(of chunk: UploadChunk, in fileURL: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        return try transfer(chunk, from: input, to: nil)
    }

    /// 把 `source` 全部内容流式追加到 `output`。
    static func copyAll(from source: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var done = false
        while !done {
            try withBufferPool {
                guard let data = try input.read(upToCount: bufferSize), !data.isEmpty else {
                    done = true
                    return
                }
                try output.write(contentsOf: data)
            }
        }
    }

    /// 读取 `chunk` 范围（可选写入 `output`），返回其 SHA-256。
    private static func transfer(_ chunk: UploadChunk, from input: FileHandle, to output: FileHandle?) throws -> String {
        try input.seek(toOffset: UInt64(chunk.offset))
        var hasher = SHA256()
        var remaining = chunk.length
        while remaining > 0 {
            try withBufferPool {
                let count = Int(min(Int64(bufferSize), remaining))
                guard let data = try input.read(upToCount: count), !data.isEmpty else { throw shortRead }
                hasher.update(data: data)
                try output?.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
        }
        return ContentDigest.hex(hasher.finalize())
    }

    /// 每轮缓冲及时释放（Darwin 上 Data 可能挂在自动释放池里；Linux 没有自动释放池）。
    static func withBufferPool(_ body: () throws -> Void) rethrows {
        #if canImport(ObjectiveC)
        try autoreleasepool(invoking: body)
        #else
        try body()
        #endif
    }

    private static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static var shortRead: CloudreveAPIError { .transport("short read") }
}
