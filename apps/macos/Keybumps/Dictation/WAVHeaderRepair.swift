import Foundation

/// Repairs the size fields of a WAV recording whose writer never closed it (#293).
///
/// `AVAudioFile` writes the RIFF and `data` chunk sizes only when the file closes, so after a
/// crash or force quit a Dictation recording's audio is on disk but its header says the audio is
/// empty, and a History retry reads no samples. The repair finds the `data` chunk, sizes it to
/// the whole frames on disk, and sizes the RIFF chunk to match. Only those two header fields are
/// rewritten, never the audio. A file whose `data` size already fits its audio, or that isn't a
/// WAV this can read, is left as it is.
enum WAVHeaderRepair {
    /// A little-endian 32-bit size field to write at `offset`.
    struct Patch: Equatable {
        let offset: UInt64
        let value: UInt32
    }

    /// How much of the file is read to find the `data` chunk. `AVAudioFile` starts it at 4,088.
    static let headerReadLength = 64 * 1_024

    /// The size fields to rewrite for a file of `fileLength` bytes that starts with `header`, or
    /// none when the header is already right or isn't one this can repair.
    static func patches(header: Data, fileLength: UInt64) -> [Patch] {
        let bytes = [UInt8](header.prefix(headerReadLength))
        guard bytes.count >= 12, fileLength >= UInt64(bytes.count),
              fourCC(bytes, at: 0) == "RIFF", fourCC(bytes, at: 8) == "WAVE" else { return [] }

        var blockAlign: UInt64?
        var position = 12
        while position + 8 <= bytes.count {
            let id = fourCC(bytes, at: position)
            let size = UInt64(uint32(bytes, at: position + 4))
            let body = position + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= bytes.count else { return [] }
                blockAlign = UInt64(bytes[body + 12]) | UInt64(bytes[body + 13]) << 8
            } else if id == "data" {
                guard let blockAlign, blockAlign > 0 else { return [] }
                let dataOffset = UInt64(body)
                let onDisk = fileLength - dataOffset
                // A nonzero size that fits the file is a closed file's (it may have chunks after it).
                guard size == 0 || size > onDisk else { return [] }
                let dataSize = onDisk - onDisk % blockAlign
                let riffSize = dataOffset - 8 + dataSize
                guard dataSize > 0, riffSize <= UInt64(UInt32.max) else { return [] }
                return [
                    Patch(offset: 4, value: UInt32(riffSize)),
                    Patch(offset: UInt64(position + 4), value: UInt32(dataSize)),
                ].filter { UInt64(uint32(bytes, at: Int($0.offset))) != UInt64($0.value) }
            }
            let next = UInt64(body) + size + size % 2
            guard next <= UInt64(bytes.count) else { return [] }
            position = Int(next)
        }
        return []
    }

    /// Rewrites the size fields `patches` finds in the file at `url`, in place. Returns whether
    /// it changed the file; a missing, unreadable, or already-correct file is left alone.
    @discardableResult
    static func repairFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            let fileLength = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: headerReadLength) ?? Data()
            let patches = patches(header: header, fileLength: fileLength)
            guard !patches.isEmpty else { return false }
            for patch in patches {
                try handle.seek(toOffset: patch.offset)
                try handle.write(contentsOf: withUnsafeBytes(of: patch.value.littleEndian) { Data($0) })
            }
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }

    private static func fourCC(_ bytes: [UInt8], at offset: Int) -> String {
        String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { value, index in value | UInt32(bytes[offset + index]) << (8 * index) }
    }
}
