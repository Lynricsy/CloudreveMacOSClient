import Foundation

/// 按扩展名推断 MIME 类型（上传会话需要）。未知类型为 `application/octet-stream`。
public enum MIMETypes {
    private static let table: [String: String] = [
        "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "html": "text/html", "htm": "text/html",
        "css": "text/css", "js": "text/javascript", "json": "application/json", "xml": "application/xml",
        "pdf": "application/pdf", "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
        "7z": "application/x-7z-compressed", "rar": "application/vnd.rar",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "svg": "image/svg+xml", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "flac": "audio/flac",
        "mp4": "video/mp4", "mov": "video/quicktime", "mkv": "video/x-matroska", "webm": "video/webm"
    ]

    public static let fallback = "application/octet-stream"

    public static func guess(_ fileExtension: String) -> String {
        table[fileExtension.lowercased()] ?? fallback
    }

    public static func guess(fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fallback }
        return guess(String(fileName[fileName.index(after: dot)...]))
    }
}
