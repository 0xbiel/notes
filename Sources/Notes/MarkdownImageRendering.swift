import AppKit
import ImageIO

struct RenderedMarkdownImage {
    let range: NSRange
    let image: NSImage
    let url: URL
    let markdown: String
    let crop: NSRect
    let requestedWidth: CGFloat?
    let size: NSSize
    var foldedRange: NSRange { NSRange(location: range.location + 1, length: range.length - 1) }
}

private final class CachedDocumentImage: NSObject {
    let image: NSImage
    let width: Int
    let height: Int
    init(image: NSImage, width: Int, height: Int) { self.image = image; self.width = width; self.height = height }
}
@MainActor enum MarkdownImageRenderer {
    private static let cache: NSCache<NSString, CachedDocumentImage> = {
        let cache = NSCache<NSString, CachedDocumentImage>(); cache.countLimit = 16; cache.totalCostLimit = 128_000_000; return cache
    }()
    static func render(source sourceText: String, directory: URL?, root: URL?, width: CGFloat) -> [RenderedMarkdownImage] {
        guard let directory, let root else { return [] }
        let pattern = #"(?m)^[ \t]*!\[[^\]\n]*\]\(([^\n)]+)\)(?:[ \t]+<!-- palladium-image ([^\n]*?) -->)?[ \t]*$"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: sourceText, range: NSRange(location: 0, length: sourceText.utf16.count)) ?? []
        return matches.compactMap { match in
            var path = (sourceText as NSString).substring(with: match.range(at: 1))
            if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
            guard !path.hasPrefix("/"), !path.contains(":"), let decoded = path.removingPercentEncoding else { return nil }
            let url = directory.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
            let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(boundary), let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let bytes = values.fileSize, bytes <= 20_000_000 else { return nil }
            let key = "\(url.path):\(bytes):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)" as NSString
            let cached: CachedDocumentImage
            if let existing = cache.object(forKey: key) { cached = existing }
            else {
                guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 12_000, h <= 12_000, w * h <= 40_000_000,
                      CGImageSourceGetCount(source) <= 500, w * h * CGImageSourceGetCount(source) <= 100_000_000,
                      let image = NSImage(data: data) else { return nil }
                cached = CachedDocumentImage(image: image, width: w, height: h)
                cache.setObject(cached, forKey: key, cost: w * h * max(1, CGImageSourceGetCount(source)) * 4)
            }
            let image = cached.image, w = cached.width, h = cached.height
            let metadata = match.range(at: 2).location == NSNotFound ? "" : (sourceText as NSString).substring(with: match.range(at: 2))
            let fields = Dictionary(metadata.split(separator: ";").compactMap { field -> (String, String)? in
                let pieces = field.split(separator: "=", maxSplits: 1); return pieces.count == 2 ? (String(pieces[0]), String(pieces[1])) : nil
            }, uniquingKeysWith: { _, new in new })
            let requested = fields["width"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 48 && $0 <= 2000 ? CGFloat($0) : nil }
            let coordinates = fields["crop"]?.split(separator: ",").compactMap { Double($0) } ?? []
            var crop = NSRect(x: 0, y: 0, width: 1, height: 1)
            if coordinates.count == 4, coordinates.allSatisfy({ $0.isFinite }), coordinates[0] >= 0, coordinates[1] >= 0, coordinates[2] >= 0.02, coordinates[3] >= 0.02, coordinates[0] + coordinates[2] <= 1.00001, coordinates[1] + coordinates[3] <= 1.00001 {
                crop = NSRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
            }
            let croppedWidth = CGFloat(w) * crop.width, croppedHeight = CGFloat(h) * crop.height
            let defaultWidth = min(croppedWidth, 400 * croppedWidth / croppedHeight)
            let displayWidth = min(1200 * croppedWidth / croppedHeight, max(48, min(max(48, width - 16), requested ?? defaultWidth)))
            let markdown = (sourceText as NSString).substring(with: match.range).components(separatedBy: "<!-- palladium-image")[0].trimmingCharacters(in: .whitespaces)
            return RenderedMarkdownImage(range: match.range, image: image, url: url, markdown: markdown, crop: crop, requestedWidth: requested, size: NSSize(width: displayWidth, height: displayWidth * croppedHeight / croppedWidth))
        }
    }
}
