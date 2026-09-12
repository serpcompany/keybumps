import AppKit
import Foundation
import Observation

struct ClipboardEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let capturedAt: Date
}

@MainActor
@Observable
final class ClipboardHistoryService {
    private(set) var entries: [ClipboardEntry] = []
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let storageURL: URL

    init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SuperMac", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storageURL = storageURL ?? directory.appendingPathComponent("clipboard-history.json")
        if let data = try? Data(contentsOf: self.storageURL), let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            entries = Array(decoded.prefix(10))
        }
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func delete(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() { entries.removeAll(); persist() }

    func restore(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func ingestForTesting(_ text: String) {
        ingest(text)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        ingest(text)
    }

    private func ingest(_ text: String) {
        guard entries.first?.text != text else { return }
        entries.removeAll { $0.text == text }
        entries.insert(ClipboardEntry(id: UUID(), text: text, capturedAt: Date()), at: 0)
        if entries.count > 10 { entries.removeLast(entries.count - 10) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
