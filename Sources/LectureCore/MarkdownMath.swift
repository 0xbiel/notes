import Foundation

public struct MarkdownMathSpan: Equatable, Sendable {
    public var range: NSRange
    public var content: NSRange
    public var display: Bool
}

public enum MarkdownMath {
    /// UTF-16 ranges keep source, selection and undo untouched in TextKit.
    public static func spans(in text: String, excluding supplied: [NSRange] = []) -> [MarkdownMathSpan] {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var excluded = supplied
        // Fenced and inline code are literal, including unclosed fences.
        let lines = text.components(separatedBy: "\n")
        var offset = 0, opening: (offset: Int, marker: String)?
        for line in lines {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if let start = opening {
                if trim.hasPrefix(start.marker) {
                    excluded.append(NSRange(location: start.offset, length: offset + line.utf16.count - start.offset)); opening = nil
                }
            } else if trim.hasPrefix("```") || trim.hasPrefix("~~~") {
                let marker = String(trim.prefix { $0 == trim.first! })
                opening = (offset, marker)
            }
            offset += line.utf16.count + 1
        }
        if let start = opening { excluded.append(NSRange(location: start.offset, length: source.length - start.offset)) }
        let code = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1"#)
        excluded += code.matches(in: text, range: full).map(\.range)
        func escaped(_ index: Int) -> Bool {
            var i = index - 1, count = 0
            while i >= 0 && source.character(at: i) == 92 { count += 1; i -= 1 }
            return count % 2 == 1
        }
        func has(_ value: String, at index: Int) -> Bool {
            index + value.utf16.count <= source.length && source.substring(with: NSRange(location: index, length: value.utf16.count)) == value
        }
        var result: [MarkdownMathSpan] = [], index = 0
        while index < source.length {
            if let skip = excluded.first(where: { NSLocationInRange(index, $0) }) { index = NSMaxRange(skip); continue }
            let opener: String, closer: String, display: Bool
            if !escaped(index), has("$$", at: index) { opener = "$$"; closer = "$$"; display = true }
            else if !escaped(index), has("$", at: index) { opener = "$"; closer = "$"; display = false }
            else if !escaped(index), has("\\(", at: index) { opener = "\\("; closer = "\\)"; display = false }
            else if !escaped(index), has("\\[", at: index) { opener = "\\["; closer = "\\]"; display = true }
            else { index += 1; continue }
            let start = index + opener.utf16.count
            var end = start, found: Int?
            while end < source.length {
                if !display && source.character(at: end) == 10 { break }
                if !escaped(end), has(closer, at: end) {
                    // Currency pairs ($5 and $10) aren't math delimiters.
                    let next = end + closer.utf16.count
                    let followedByDigit = closer == "$" && next < source.length && (48...57).contains(source.character(at: next))
                    if !followedByDigit { found = end; break }
                }
                end += 1
            }
            if let end = found, end > start {
                let range = NSRange(location: index, length: end + closer.utf16.count - index)
                let content = NSRange(location: start, length: end - start)
                let body = source.substring(with: content)
                let validWhitespace = display || (body.first?.isWhitespace == false && body.last?.isWhitespace == false)
                if validWhitespace, !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                    result.append(.init(range: range, content: content, display: display)); index = NSMaxRange(range); continue
                }
            }
            index += opener.utf16.count
        }
        return result
    }
}
