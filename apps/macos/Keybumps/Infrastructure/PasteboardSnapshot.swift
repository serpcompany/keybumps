import AppKit

/// Every item and type on a pasteboard, read in full, so keyword expansion can put the user's
/// clipboard back after pasting a snippet over it. Held only in memory, and never logged.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                types[type] = item.data(forType: type)
            }
            return types
        }
    }

    /// Replaces the pasteboard's contents with the snapshot's. A concealed item stays on this Mac,
    /// as `writeText(_:concealed:)` keeps it.
    func restore(to pasteboard: NSPasteboard) {
        let concealed = items.contains { $0[.concealed] != nil }
        pasteboard.prepareForNewContents(with: NSPasteboard.contentsOptions(concealed: concealed))
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
