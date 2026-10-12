import Foundation
import AppKit
import PDFKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

public struct NotebookImageCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width >= 0.01, height >= 0.01, x + width <= 1, y + height <= 1 else {
            throw MediaError.invalid("Image crop must use normalized top-left coordinates inside the image.")
        }
    }
}

public enum NotebookSourceImage {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func png(_ data: Data, filename: String, page: Int? = nil, crop: NotebookImageCrop? = nil) throws -> Data {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw MediaError.invalid("Image/PDF source exceeds 64 MB.") }
        try crop?.validate()
        let image: CGImage
        if (filename as NSString).pathExtension.lowercased() == "pdf" {
            guard let page, page > 0, let document = PDFDocument(data: data), !document.isLocked,
                  page <= document.pageCount, let selected = document.page(at: page - 1) else {
                throw MediaError.invalid("PDF image extraction requires an existing, one-based page number.")
            }
            let bounds = selected.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw MediaError.invalid("Invalid PDF page dimensions.")
            }
            let thumbnail = selected.thumbnail(of: NSSize(width: 2400, height: 2400), for: .mediaBox)
            guard let rendered = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw MediaError.invalid("The PDF page could not be rendered.")
            }
            image = rendered
        } else {
            guard page == nil, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 12_000, height <= 12_000, width * height <= 40_000_000,
                  let rendered = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400
                  ] as CFDictionary) else { throw MediaError.invalid("The source is not a supported image.") }
            image = rendered
        }
        let result: CGImage
        if let crop {
            let rect = CGRect(x: crop.x * Double(image.width), y: crop.y * Double(image.height),
                              width: crop.width * Double(image.width), height: crop.height * Double(image.height)).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
                throw MediaError.invalid("The selected crop is empty.")
            }
            result = cropped
        } else { result = image }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaError.invalid("Image encoding failed.")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= 20 * 1024 * 1024 else {
            throw MediaError.invalid("The extracted image exceeds 20 MB.")
        }
        return encoded as Data
    }
}
