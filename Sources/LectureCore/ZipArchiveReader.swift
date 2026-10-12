import Foundation
import Compression

/// Reads the files inside a ZIP archive in memory; nothing is ever unpacked to disk.
public struct ZipArchiveReader {
    public struct Entry: Sendable {
        public let name: String
        public let size: Int
        let compressedSize: Int, method: Int, offset: Int, encrypted: Bool
    }
    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        // Rebased so offsets recorded in the archive are indices.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        let damaged = MediaError.invalid("This ZIP archive is damaged or unreadable.")
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func u64(_ at: Int) -> Int { Int(truncatingIfNeeded: UInt64(u32(at)) | UInt64(u32(at + 4)) << 32) }
        // The end record closes the archive, followed only by an optional comment.
        guard data.count >= 22, let end = stride(from: data.count - 22, through: max(0, data.count - 22 - 65_535), by: -1).first(where: { u32($0) == 0x0605_4b50 }) else { throw damaged }
        var count = u16(end + 10), cursor = u32(end + 16)
        // Archives past 4 GB or 65,535 files keep their real figures in a second, wider end record.
        if end >= 20, u32(end - 20) == 0x0706_4b50 {
            let wide = u64(end - 12)
            guard wide >= 0, wide + 56 <= data.count, u32(wide) == 0x0606_4b50 else { throw damaged }
            count = u64(wide + 32); cursor = u64(wide + 48)
        }
        var found: [Entry] = []
        for _ in 0..<max(0, count) {
            guard cursor >= 0, cursor + 46 <= data.count, u32(cursor) == 0x0201_4b50 else { throw damaged }
            let flags = u16(cursor + 8), nameLength = u16(cursor + 28), extraLength = u16(cursor + 30)
            guard cursor + 46 + nameLength + extraLength <= data.count else { throw damaged }
            let raw = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
            var size = u32(cursor + 24), compressedSize = u32(cursor + 20), offset = u32(cursor + 42)
            // A figure too wide for its field is stored in the entry's extra data instead, in this order.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let kind = u16(extra), length = u16(extra + 2)
                var field = extra + 4
                extra = field + length
                guard kind == 1, extra <= extraEnd else { continue }
                if size == 0xFFFF_FFFF, field + 8 <= extra { size = u64(field); field += 8 }
                if compressedSize == 0xFFFF_FFFF, field + 8 <= extra { compressedSize = u64(field); field += 8 }
                if offset == 0xFFFF_FFFF, field + 8 <= extra { offset = u64(field) }
            }
            // Folders and macOS metadata are not files to read.
            if !name.hasSuffix("/"), !name.hasPrefix("__MACOSX/"), (name as NSString).lastPathComponent != ".DS_Store" {
                found.append(Entry(name: name, size: size, compressedSize: compressedSize, method: u16(cursor + 10), offset: offset, encrypted: flags & 1 == 1))
            }
            cursor += 46 + nameLength + extraLength + u16(cursor + 32)
        }
        entries = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The file with this path inside the archive; a bare or differently cased name is accepted when only one file answers to it.
    public func entry(named name: String) -> Entry? {
        let wanted = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let exact = entries.first(where: { $0.name == wanted }) { return exact }
        let loose = entries.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.lowercased().hasSuffix("/" + wanted.lowercased()) }
        return loose.count == 1 ? loose[0] : nil
    }

    public func contents(of entry: Entry) throws -> Data {
        let damaged = MediaError.invalid("\(entry.name) is damaged inside the ZIP archive.")
        guard !entry.encrypted else { throw MediaError.invalid("\(entry.name) is password-protected inside the ZIP archive.") }
        guard entry.offset >= 0, entry.offset + 30 <= data.count, data[entry.offset] == 0x50, data[entry.offset + 1] == 0x4b, data[entry.offset + 2] == 3, data[entry.offset + 3] == 4 else { throw damaged }
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard entry.compressedSize >= 0, entry.size >= 0, start + entry.compressedSize <= data.count else { throw damaged }
        let packed = data.subdata(in: start..<(start + entry.compressedSize))
        if entry.method == 0 { return packed }
        guard entry.method == 8 else { throw MediaError.invalid("\(entry.name) uses a compression method that cannot be read.") }
        // Deflate cannot expand beyond about 1032 times, so a larger claim is not a real size.
        guard entry.size <= packed.count * 1_100 + 64 else { throw damaged }
        if entry.size == 0 { return Data() }
        var output = Data(count: entry.size)
        let written = output.withUnsafeMutableBytes { target in
            packed.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, entry.size, source.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.size else { throw damaged }
        return output
    }
}
