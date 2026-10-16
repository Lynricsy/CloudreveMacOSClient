import Foundation

/// 分片规划。
public enum UploadPlan {
    /// 按 `chunkSize` 切分文件；`chunkSize <= 0` 表示整文件一块。
    public static func chunks(size: Int64, chunkSize: Int64) -> [UploadChunk] {
        guard chunkSize > 0, size > chunkSize else {
            return [UploadChunk(index: 0, offset: 0, length: max(0, size))]
        }
        var result: [UploadChunk] = []
        var offset: Int64 = 0
        while offset < size {
            let length = min(chunkSize, size - offset)
            result.append(UploadChunk(index: result.count, offset: offset, length: length))
            offset += length
        }
        return result
    }
}
