import AppKit

enum InlineUnderline {
    struct Span {
        let opening: NSRange
        let content: NSRange
        let closing: NSRange
        var range: NSRange { NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location) }
    }
    static func spans(in text: String, excluding protected: [NSRange] = []) -> [Span] {
        let source = text as NSString
        let pattern = #"(?i)(?<!\\)</?u\s*>"#
        let tags = (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []
        var stack: [NSRange] = [], spans: [Span] = []
        for tag in tags where !protected.contains(where: { NSIntersectionRange($0, tag.range).length > 0 }) {
            if source.substring(with: tag.range).hasPrefix("</") {
                if let opening = stack.popLast() {
                    spans.append(Span(opening: opening,
                        content: NSRange(location: NSMaxRange(opening), length: tag.range.location - NSMaxRange(opening)), closing: tag.range))
                }
            } else { stack.append(tag.range) }
        }
        return spans
    }

    /// Foundation handles Markdown; paired underline tags add presentation only.
    /// Code spans and unmatched/escaped tags remain literal.
    static func attributed(_ text: String) -> AttributedString {
        let source = text as NSString
        let code = (try? NSRegularExpression(pattern: #"(?<!\\)(`+)[\s\S]*?\1"#))?
            .matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range) ?? []
        let pairs = spans(in: text, excluding: code)
        guard !pairs.isEmpty else {
            return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
        var scalar: UInt32 = 0xE000
        while text.contains(String(UnicodeScalar(scalar)!)) || text.contains(String(UnicodeScalar(scalar + 1)!)) { scalar += 2 }
        let opening = String(UnicodeScalar(scalar)!), closing = String(UnicodeScalar(scalar + 1)!)
        let marked = NSMutableString(string: text)
        let tags = pairs.flatMap { [($0.opening, opening), ($0.closing, closing)] }.sorted { $0.0.location > $1.0.location }
        for (range, marker) in tags { marked.replaceCharacters(in: range, with: marker) }
        let parsed = (try? AttributedString(markdown: marked as String, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(marked as String)
        let rendered = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let markers = (try? NSRegularExpression(pattern: "[" + opening + closing + "]"))?
            .matches(in: rendered.string, range: NSRange(location: 0, length: rendered.length)) ?? []
        var stack: [Int] = []
        for marker in markers {
            if (rendered.string as NSString).substring(with: marker.range) == opening { stack.append(NSMaxRange(marker.range)) }
            else if let start = stack.popLast() {
                rendered.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: start, length: marker.range.location - start))
            }
        }
        for marker in markers.reversed() { rendered.deleteCharacters(in: marker.range) }
        return AttributedString(rendered)
    }
}
