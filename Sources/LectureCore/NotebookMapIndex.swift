import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// One place in a notebook that the map can show and open.
public struct NotebookMapItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Part of a note, under one heading.
        case section
        /// A PDF page with text.
        case page
        /// A PDF page without text, read as a picture.
        case scan
        /// A picture: one of the library, or one shown in a note (then `host` names its section).
        case image
    }
    public var id: String
    public var kind: Kind
    /// The file that opens: the note for a section or a picture in it, otherwise the document.
    public var path: String
    public var heading: String?
    public var page: Int?
    public var image: String?
    public var host: String?
    public var title: String
    /// Name of the file, shown where several of its parts are grouped.
    public var file: String
    /// Name of the folder that holds the file inside the notebook, if it is in one.
    public var folder: String?
    /// The vector is kept while this matches the content.
    public var digest: String
    public init(id: String, kind: Kind, path: String, heading: String? = nil, page: Int? = nil, image: String? = nil, host: String? = nil, title: String, file: String, folder: String? = nil, digest: String) {
        self.id = id; self.kind = kind; self.path = path; self.heading = heading; self.page = page; self.image = image; self.host = host
        self.title = title; self.file = file; self.folder = folder; self.digest = digest
    }
    /// Pictures and scanned pages are compared with text, not with each other, to find their place.
    public var visual: Bool { kind == .scan || kind == .image }
}

public struct NotebookMapIndex: Codable, Sendable {
    public struct Stamp: Codable, Equatable, Sendable { var size: Int64; var modified: Double }
    public struct Entry: Codable, Sendable {
        public var item: NotebookMapItem
        /// Little-endian Float32 values; empty for a picture placed by the note that shows it.
        public var vector: Data
        public init(item: NotebookMapItem, vector: Data) { self.item = item; self.vector = vector }
    }
    public var model = NotebookEmbeddingRuntime.identity
    public var stamps: [String: Stamp] = [:]
    public var entries: [Entry] = []
    /// Vectors of the names a branch can take: headings and file names.
    public var titles: [String: Data] = [:]
    public init() {}

    public static func pack(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }
    public static func unpack(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { raw in (0..<data.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }
    private static func location(_ notebookID: String) -> String {
        "maps/" + notebookID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
    }
    public static func load(notebookID: String, workspace: SafeWorkspace) -> NotebookMapIndex? {
        guard let data = try? workspace.readStorage(location(notebookID) + "/index.plist"),
              let index = try? PropertyListDecoder().decode(NotebookMapIndex.self, from: data), index.model == NotebookEmbeddingRuntime.identity else { return nil }
        return index
    }
    public func save(notebookID: String, workspace: SafeWorkspace) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try workspace.writeStorage(Self.location(notebookID) + "/index.plist", data: encoder.encode(self))
    }
    public static func remove(notebookID: String, workspace: SafeWorkspace) {
        try? workspace.removeStorage(location(notebookID) + "/index.plist")
    }
}

/// Reads a notebook's files into the pieces the map is made of.
public enum NotebookMapScanner {
    public enum Content: Sendable {
        case text(String)
        case image(path: String)
        case pdfPage(path: String, index: Int)
        /// Shown beside its section; needs no vector of its own.
        case none
    }
    public struct Piece: Sendable { public var item: NotebookMapItem; public var content: Content }
    public struct Result: Sendable {
        /// Entries carried over, and pieces whose vector must still be made, in the notebook's order.
        public var kept: [NotebookMapIndex.Entry] = []
        public var pending: [Piece] = []
        public var order: [String] = []
        public var stamps: [String: NotebookMapIndex.Stamp] = [:]
    }
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
    static let pagesPerPDF = 150, itemLimit = 4_000
    /// Shorter page text is usually a title or a page number over a scanned picture.
    static let pageTextMinimum = 200

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func name(_ path: String) -> String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    /// The folder directly holding a file, when it lies below the notebook's own folder.
    static func folder(_ path: String, root: String) -> String? {
        let inside = root.isEmpty ? path : path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let parts = inside.components(separatedBy: "/").dropLast()
        return parts.last.flatMap { $0.hasPrefix(".") ? nil : $0 }
    }

    /// A note is cut at its headings of the first three levels; deeper ones stay with their parent.
    static func sections(_ markdown: String) -> [(heading: String?, trail: [String], body: String)] {
        var result: [(heading: String?, trail: [String], body: String)] = []
        var heading: String?, trail: [String] = [], levels: [(Int, String)] = [], body: [String] = [], inCode = false
        func close() {
            if heading != nil || body.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { result.append((heading, trail, body.joined(separator: "\n"))) }
            body = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle(); body.append(line); continue }
            let hashes = inCode ? 0 : line.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 3, line.dropFirst(hashes).hasPrefix(" ") {
                close()
                let text = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
                levels.removeAll { $0.0 >= hashes }
                trail = levels.map(\.1); levels.append((hashes, text)); heading = text
            } else { body.append(line) }
        }
        close()
        return result
    }
    /// Local pictures a piece of Markdown shows, as workspace paths.
    static func pictures(_ markdown: String, note: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(<?([^)>\\s]+)>?[^)]*\\)") else { return [] }
        let directory = note.components(separatedBy: "/").dropLast()
        var found: [String] = []
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let range = Range(match.range(at: 1), in: markdown) else { continue }
            let target = String(markdown[range])
            guard !target.contains(":"), !target.hasPrefix("/"), let decoded = target.removingPercentEncoding else { continue }
            var parts = Array(directory)
            var inside = true
            for part in decoded.components(separatedBy: "/") where !part.isEmpty && part != "." {
                if part == ".." { if parts.isEmpty { inside = false; break }; parts.removeLast() } else { parts.append(part) }
            }
            let path = parts.joined(separator: "/")
            if inside, imageExtensions.contains((path as NSString).pathExtension.lowercased()), !found.contains(path) { found.append(path) }
        }
        return found
    }
    private static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").filter { !($0.hasPrefix("<!--") && $0.hasSuffix("-->")) }.joined(separator: "\n")
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pieces(note path: String, markdown: String, root: String = "", workspace: SafeWorkspace) -> [Piece] {
        let file = name(path), folder = folder(path, root: root)
        var result: [Piece] = [], seen: [String: Int] = [:]
        for section in sections(markdown) {
            let text = plain(section.body), shown = pictures(section.body, note: path).filter { (try? workspace.fileURL($0)).map { FileManager.default.fileExists(atPath: $0.path) } == true }
            // A heading with nothing under it is only a container for the ones that follow.
            guard text.count >= 24 || !shown.isEmpty else { continue }
            let anchor = section.heading ?? ""
            seen[anchor, default: 0] += 1
            let id = path + "#" + anchor + (seen[anchor]! > 1 ? "#\(seen[anchor]!)" : "")
            let context = ([file] + section.trail + [section.heading].compactMap { $0 }).joined(separator: " › ")
            let embedded = context + "\n\n" + text
            result.append(Piece(item: .init(id: id, kind: .section, path: path, heading: section.heading, title: section.heading ?? file, file: file, folder: folder, digest: digest(Data(embedded.utf8))), content: .text(embedded)))
            for picture in shown {
                let data = (try? workspace.readFile(picture)) ?? Data()
                result.append(Piece(item: .init(id: id + "|" + picture, kind: .image, path: path, heading: section.heading, image: picture, host: id, title: name(picture), file: file, digest: digest(data)), content: .none))
            }
        }
        return result
    }
    static func pieces(pdf path: String, root: String = "", workspace: SafeWorkspace) throws -> [Piece] {
        let data = try workspace.readFile(path), source = digest(data), file = name(path)
        guard let document = PDFDocument(data: data), !document.isLocked else { return [] }
        return (0..<min(document.pageCount, pagesPerPDF)).map { index in
            let text = (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let scanned = text.count < pageTextMinimum
            let item = NotebookMapItem(id: path + "#page=\(index + 1)", kind: scanned ? .scan : .page, path: path, page: index + 1, title: file + " · " + String(index + 1), file: file, folder: folder(path, root: root),
                                       digest: digest(Data((source + "/\(index)/" + (scanned ? "scan" : "text")).utf8)))
            return Piece(item: item, content: scanned ? .pdfPage(path: path, index: index) : .text(file + " › " + String(index + 1) + "\n\n" + text))
        }
    }

    /// `paths` are the notebook's notes and library files, and `root` its folder. A file whose size and date are unchanged keeps
    /// its entries without being read; in a changed one, parts with the same content keep their vector.
    public static func scan(paths: [String], root: String = "", workspace: SafeWorkspace, previous: NotebookMapIndex?) throws -> Result {
        var result = Result()
        var before: [String: [NotebookMapIndex.Entry]] = [:], known: [String: NotebookMapIndex.Entry] = [:]
        for entry in previous?.entries ?? [] { before[entry.item.path, default: []].append(entry); known[entry.item.id] = entry }
        // As the sidebar lists them: by name, without the extension.
        func key(_ path: String) -> String { (path as NSString).deletingPathExtension }
        for path in paths.sorted(by: { (key($0), $0) < (key($1), $1) }) where result.order.count < itemLimit {
            try Task.checkCancellation()
            let ext = (path as NSString).pathExtension.lowercased()
            guard ext == "md" || ext == "pdf" || imageExtensions.contains(ext), let url = try? workspace.fileURL(path),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let stamp = NotebookMapIndex.Stamp(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            result.stamps[path] = stamp
            if previous?.stamps[path] == stamp, let entries = before[path] {
                result.kept += entries; result.order += entries.map(\.item.id); continue
            }
            var pieces: [Piece]
            switch ext {
            case "md": pieces = self.pieces(note: path, markdown: (try? workspace.readNote(path)) ?? "", root: root, workspace: workspace)
            case "pdf": pieces = (try? self.pieces(pdf: path, root: root, workspace: workspace)) ?? []
            default:
                // Pictures the app keeps for notes appear with the note that shows them.
                guard !path.contains(".palladium-images/"), let data = try? workspace.readFile(path) else { continue }
                pieces = [Piece(item: .init(id: path, kind: .image, path: path, image: path, title: name(path), file: name(path), folder: folder(path, root: root), digest: digest(data)), content: .image(path: path))]
            }
            for piece in pieces.prefix(itemLimit - result.order.count) {
                result.order.append(piece.item.id)
                if let old = known[piece.item.id], old.item.digest == piece.item.digest, !old.vector.isEmpty || piece.item.host != nil {
                    result.kept.append(.init(item: piece.item, vector: old.vector))
                } else if case .none = piece.content { result.kept.append(.init(item: piece.item, vector: Data())) }
                else { result.pending.append(piece) }
            }
        }
        return result
    }

    /// A picture or a PDF page as a PNG small enough to embed quickly.
    public static func picture(_ content: Content, workspace: SafeWorkspace) throws -> Data {
        let image: CGImage
        switch content {
        case .image(let path):
            guard let source = CGImageSourceCreateWithData(try workspace.readFile(path) as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 896, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw MediaError.invalid("This image cannot be read.") }
            image = thumbnail
        case .pdfPage(let path, let index):
            guard let page = PDFDocument(data: try workspace.readFile(path))?.page(at: index),
                  let rendered = page.thumbnail(of: NSSize(width: 896, height: 896), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw MediaError.invalid("This page cannot be read.") }
            image = rendered
        default: throw MediaError.invalid("Not a picture.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw MediaError.invalid("Could not prepare image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.invalid("Could not prepare image.") }
        return output as Data
    }
}

public enum NotebookMapIndexer {
    /// EmbeddingGemma's instruction for texts that are compared with each other.
    static let prefix = "task: clustering | query: "

    /// Makes the missing vectors and returns the index in the notebook's order. `changed` tells whether
    /// anything differs from `previous`, so an unchanged notebook does not redraw its map.
    public static func update(scan: NotebookMapScanner.Result, previous: NotebookMapIndex?, workspace: SafeWorkspace, embedder: NotebookEmbedder,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> (index: NotebookMapIndex, changed: Bool) {
        var entries: [String: NotebookMapIndex.Entry] = [:]
        for entry in scan.kept { entries[entry.item.id] = entry }
        let total = scan.pending.count
        var done = 0
        progress(done, total)
        let texts = scan.pending.compactMap { piece -> (NotebookMapItem, String)? in if case .text(let text) = piece.content { return (piece.item, text) }; return nil }
        for start in stride(from: 0, to: texts.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(texts[start..<min(start + 8, texts.count)])
            let vectors = try await embedder.embed(texts: batch.map { prefix + $0.1 })
            for (pair, vector) in zip(batch, vectors) { entries[pair.0.id] = .init(item: pair.0, vector: NotebookMapIndex.pack(vector)) }
            done += batch.count; progress(done, total)
        }
        for piece in scan.pending {
            switch piece.content { case .text, .none: continue; default: break }
            try Task.checkCancellation()
            // One unreadable picture leaves the rest of the notebook mapped.
            if let data = try? NotebookMapScanner.picture(piece.content, workspace: workspace) {
                entries[piece.item.id] = .init(item: piece.item, vector: NotebookMapIndex.pack(try await embedder.embed(image: data)))
            }
            done += 1; progress(done, total)
        }
        var index = NotebookMapIndex()
        index.stamps = scan.stamps
        index.entries = scan.order.compactMap { entries[$0] }
        let names = Set(index.entries.filter { !$0.item.visual }.flatMap { [$0.item.title, $0.item.file] })
        index.titles = (previous?.titles ?? [:]).filter { names.contains($0.key) }
        let missing = names.subtracting(index.titles.keys).sorted()
        for start in stride(from: 0, to: missing.count, by: 16) {
            try Task.checkCancellation()
            let batch = Array(missing[start..<min(start + 16, missing.count)])
            for (name, vector) in zip(batch, try await embedder.embed(texts: batch.map { prefix + $0 })) { index.titles[name] = NotebookMapIndex.pack(vector) }
        }
        let changed = total > 0 || previous == nil || previous?.entries.map(\.item) != index.entries.map(\.item)
        return (index, changed)
    }
}
