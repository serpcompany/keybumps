import Compression
import Foundation

/// A small read-only zip reader for importing another app's export, such as Alfred's
/// `.alfredsnippets`. Foundation has no public unzip API, and running `ditto` or `unzip` would
/// write the entries to disk first.
///
/// It reads the central directory, then each entry's local header, and supports what exporters
/// write: stored (method 0) and deflated (method 8, through the Compression framework's raw
/// DEFLATE) entries in a single-disk, unencrypted, non-ZIP64 archive. Every size is checked against
/// `Limits` before anything is allocated, the entries' compressed data can't add up to more than the
/// file (entries never share bytes, so reading each entry once decodes no more than the file's
/// size), a deflated entry can't decode to more than its declared size, and each entry must match
/// its CRC-32. So a damaged, oversized, or hostile file is refused rather than read. Entry paths and
/// contents are never logged.
struct ZipArchive {
    struct Limits: Equatable {
        var maxArchiveBytes: Int
        var maxEntries: Int
        var maxEntryBytes: Int
        /// The sum of every entry's uncompressed size.
        var maxTotalBytes: Int

        /// Far above any real snippets export (a few kilobytes per snippet), and small enough to
        /// read at once.
        static let standard = Limits(
            maxArchiveBytes: 32 << 20,
            maxEntries: 10_000,
            maxEntryBytes: 4 << 20,
            maxTotalBytes: 32 << 20
        )
    }

    enum Failure: Error, Equatable {
        /// Not a zip archive, or its structure or an entry is damaged.
        case damaged
        /// Split, ZIP64, encrypted, or compressed some other way.
        case unsupported
        /// Over one of the `Limits`.
        case tooLarge
    }

    struct Entry: Equatable {
        /// The path inside the archive.
        let path: String
        fileprivate let flags: UInt16
        fileprivate let method: UInt16
        fileprivate let crc32: UInt32
        fileprivate let compressedSize: Int
        fileprivate let uncompressedSize: Int
        fileprivate let localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
        /// The last path component, such as `info.plist`.
        var name: String { path.split(separator: "/").last.map(String.init) ?? "" }
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    let entries: [Entry]
    private let bytes: [UInt8]

    init(data: Data, limits: Limits = .standard) throws {
        guard data.count <= limits.maxArchiveBytes else { throw Failure.tooLarge }
        bytes = [UInt8](data)
        entries = try Self.centralDirectory(of: bytes, limits: limits)
    }

    /// The entry's uncompressed contents, checked against its size and CRC-32.
    func contents(of entry: Entry) throws -> Data {
        // Bit 0: encrypted.
        guard entry.flags & 0x1 == 0 else { throw Failure.unsupported }
        let header = entry.localHeaderOffset
        guard try bytes.uint32(at: header) == Self.localHeaderSignature else { throw Failure.damaged }
        let start = header + 30 + Int(try bytes.uint16(at: header + 26)) + Int(try bytes.uint16(at: header + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw Failure.damaged }
        let stored = bytes[start..<end]

        let output: [UInt8]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw Failure.damaged }
            output = Array(stored)
        case 8:
            output = try Self.inflate(stored, size: entry.uncompressedSize)
        default:
            throw Failure.unsupported
        }
        guard Self.crc32(output) == entry.crc32 else { throw Failure.damaged }
        return Data(output)
    }

    /// The standard zip CRC-32 (the reflected 0xEDB88320 polynomial).
    static func crc32<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    // MARK: Reading

    private static func centralDirectory(of bytes: [UInt8], limits: Limits) throws -> [Entry] {
        // The end record is the last 22 bytes, followed only by an archive comment of up to 64 KB.
        let endRecordSize = 22
        guard bytes.count >= endRecordSize else { throw Failure.damaged }
        let lowest = max(0, bytes.count - endRecordSize - 0xFFFF)
        guard let end = stride(from: bytes.count - endRecordSize, through: lowest, by: -1)
            .first(where: { (try? bytes.uint32(at: $0)) == endOfCentralDirectorySignature }) else {
            throw Failure.damaged
        }
        let disk = try bytes.uint16(at: end + 4)
        let directoryDisk = try bytes.uint16(at: end + 6)
        let entriesOnDisk = try bytes.uint16(at: end + 8)
        let entryCount = try bytes.uint16(at: end + 10)
        let directorySize = try bytes.uint32(at: end + 12)
        let directoryOffset = try bytes.uint32(at: end + 16)
        // All-ones values point to a ZIP64 record.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw Failure.unsupported
        }
        guard disk == 0, directoryDisk == 0, entriesOnDisk == entryCount else { throw Failure.unsupported }
        guard Int(entryCount) <= limits.maxEntries else { throw Failure.tooLarge }
        let directoryEnd = Int(directoryOffset) + Int(directorySize)
        guard directoryEnd <= end else { throw Failure.damaged }

        var entries: [Entry] = []
        var position = Int(directoryOffset)
        var totalBytes = 0
        var totalCompressedBytes = 0
        for _ in 0..<entryCount {
            guard try bytes.uint32(at: position) == centralDirectorySignature else { throw Failure.damaged }
            let compressedSize = try bytes.uint32(at: position + 20)
            let uncompressedSize = try bytes.uint32(at: position + 24)
            let nameLength = Int(try bytes.uint16(at: position + 28))
            let extraLength = Int(try bytes.uint16(at: position + 30))
            let commentLength = Int(try bytes.uint16(at: position + 32))
            let localHeaderOffset = try bytes.uint32(at: position + 42)
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                throw Failure.unsupported
            }
            guard Int(uncompressedSize) <= limits.maxEntryBytes else { throw Failure.tooLarge }
            totalBytes += Int(uncompressedSize)
            guard totalBytes <= limits.maxTotalBytes else { throw Failure.tooLarge }
            totalCompressedBytes += Int(compressedSize)
            guard totalCompressedBytes <= bytes.count else { throw Failure.damaged }

            let nameStart = position + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= directoryEnd else { throw Failure.damaged }
            entries.append(Entry(
                path: String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self),
                flags: try bytes.uint16(at: position + 8),
                method: try bytes.uint16(at: position + 10),
                crc32: try bytes.uint32(at: position + 16),
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset)
            ))
            position = next
        }
        return entries
    }

    /// Decodes raw DEFLATE into exactly `size` bytes. One spare byte of room shows a stream that
    /// decodes to more than it declared, which is refused along with a short or invalid one.
    private static func inflate(_ compressed: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
        if size == 0 { return [] }
        guard !compressed.isEmpty else { throw Failure.damaged }
        let capacity = size + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compressed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, capacity,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw Failure.damaged }
        output.removeLast()
        return output
    }
}

private extension Array where Element == UInt8 {
    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZipArchive.Failure.damaged }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchive.Failure.damaged }
        return (0..<4).reduce(UInt32(0)) { value, index in value | UInt32(self[offset + index]) << (8 * index) }
    }
}
