import CloudreveSync
import FileProvider
import UniformTypeIdentifiers

/// 引擎条目在系统中的表示。
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let item: SyncItem
    private let rootID: String

    init(_ item: SyncItem, rootID: String) {
        self.item = item
        self.rootID = rootID
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        FileProviderBridge.identifier(item.id, rootID: rootID)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        FileProviderBridge.identifier(item.parentID, rootID: rootID)
    }

    var filename: String { item.name }

    var contentType: UTType {
        guard !item.isFolder else { return .folder }
        let ext = (item.name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting
        ]
        if item.isFolder {
            capabilities.formUnion([.allowsAddingSubItems, .allowsContentEnumerating])
        }
        return capabilities
    }

    var itemVersion: NSFileProviderItemVersion {
        let version = item.version
        return NSFileProviderItemVersion(contentVersion: Data(version.content.utf8), metadataVersion: Data(version.metadata.utf8))
    }

    var documentSize: NSNumber? {
        item.isFolder ? nil : NSNumber(value: item.size)
    }

    var contentModificationDate: Date? { item.updatedAt }

    var creationDate: Date? { item.createdAt }

    var contentPolicy: NSFileProviderContentPolicy { .inherited }
}
