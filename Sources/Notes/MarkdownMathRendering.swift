import AppKit
import SwiftUI
import SwiftMath
import LectureCore

struct RenderedMarkdownMath {
    let span: MarkdownMathSpan
    let image: NSImage
    let ascent: CGFloat
    let descent: CGFloat
    var size: NSSize { image.size }
    var foldedRange: NSRange { NSRange(location: span.range.location + 1, length: span.range.length - 1) }
}

@MainActor enum MarkdownMathRenderer {
    private final class Cached: NSObject {
        let image: NSImage; let ascent: CGFloat; let descent: CGFloat
        init(_ image: NSImage, _ ascent: CGFloat, _ descent: CGFloat) { self.image = image; self.ascent = ascent; self.descent = descent }
    }
    private static let cache: NSCache<NSString, Cached> = { let cache = NSCache<NSString, Cached>(); cache.countLimit = 256; return cache }()
    static func render(_ span: MarkdownMathSpan, source: String, fontSize: CGFloat = 16, color: NSColor = .labelColor) -> RenderedMarkdownMath? {
        let latex = (source as NSString).substring(with: span.content)
        guard latex.utf16.count <= 8_000 else { return nil }
        let resolved = color.usingColorSpace(.deviceRGB) ?? .black
        let key = "\(latex)|\(span.display)|\(fontSize)|\(resolved)" as NSString
        if let cached = cache.object(forKey: key) { return .init(span: span, image: cached.image, ascent: cached.ascent, descent: cached.descent) }
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: resolved, labelMode: span.display ? .display : .text, textAlignment: .left)
        let (error, image, info) = math.asImage()
        guard error == nil, let image, let info, image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.width < 10_000, image.size.height > 0, image.size.height < 2_000 else { return nil }
        image.accessibilityDescription = latex
        cache.setObject(Cached(image, info.ascent, info.descent), forKey: key)
        return .init(span: span, image: image, ascent: info.ascent, descent: info.descent)
    }
}

/// Rich presentation uses attachment characters; the original Markdown stays unchanged.
struct MarkdownMathText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 14
    var weight: NSFont.Weight = .regular
    var accent: NSColor = .controlAccentColor
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        view.textStorage?.setAttributedString(Self.attributed(text, fontSize: fontSize, weight: weight, accent: accent))
        view.linkTextAttributes = [.foregroundColor: accent]
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        view.textContainer?.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        return CGSize(width: width, height: ceil(view.layoutManager?.usedRect(for: view.textContainer!).height ?? 20))
    }
    static func attributed(_ source: String, fontSize: CGFloat = 14, weight: NSFont.Weight = .regular, accent: NSColor = .controlAccentColor) -> NSAttributedString {
        let spans = MarkdownMath.spans(in: source)
        var protected = source as NSString
        var renders: [(String, RenderedMarkdownMath)] = []
        for (index, span) in spans.enumerated().reversed() {
            guard let render = MarkdownMathRenderer.render(span, source: source, fontSize: span.display ? fontSize + 3 : fontSize) else { continue }
            let token = "PALLADIUMMATH\(index)TOKEN"
            renders.append((token, render)); protected = protected.replacingCharacters(in: span.range, with: token) as NSString
        }
        let rich = InlineUnderline.attributed(protected as String)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(rich))
        result.addAttributes([.font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: result.length))
        for run in rich.runs {
            let range = NSRange(location: String(rich.characters[..<run.range.lowerBound]).utf16.count, length: String(rich.characters[run.range]).utf16.count)
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: fontSize, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.code) { font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) { result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        for (token, render) in renders {
            let range = (result.string as NSString).range(of: token)
            guard range.location != NSNotFound else { continue }
            let attachment = NSTextAttachment(); attachment.image = render.image
            attachment.bounds = NSRect(x: 0, y: -render.descent, width: render.size.width, height: render.size.height)
            result.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
            if render.span.display {
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                paragraph.paragraphSpacingBefore = 8; paragraph.paragraphSpacing = 8
                result.addAttribute(.paragraphStyle, value: paragraph, range: (result.string as NSString).lineRange(for: NSRange(location: range.location, length: 1)))
            }
        }
        return result
    }
}
