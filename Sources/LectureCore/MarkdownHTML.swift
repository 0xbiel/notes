import Foundation

public struct MarkdownHTMLBlock: Sendable {
    public let range: NSRange
    public let source: String
    public let id: String
}

public struct MarkdownHTMLDocument: Sendable {
    public var blocks: [MarkdownHTMLBlock] = []
    public var supportRanges: [NSRange] = []
    public var styles = ""
    public var scripts = ""
}

/// Recognizes standalone HTML containers, preserving UTF-16 source positions.
/// Ordinary HTML code examples remain code; html-ui fences explicitly embed UI.
public enum MarkdownHTML {
    public static func parse(_ text: String) -> MarkdownHTMLDocument {
        let source = text as NSString
        let comments = MarkdownComments.ranges(in: text)
        let roots = Set(["section", "div", "article", "aside", "main", "figure", "details", "form", "header", "footer", "nav", "style", "script"])
        let tokenPattern = #"<!--[\s\S]*?-->|<(?:script|style)\b(?:[^>"']|"[^"]*"|'[^']*')*>[\s\S]*?</(?:script|style)\s*>|</?[a-zA-Z][\w:-]*\b(?:[^>"']|"[^"]*"|'[^']*')*>"#
        guard let tokens = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]),
              let tag = try? NSRegularExpression(pattern: #"^<(\/?)([a-zA-Z][\w:-]*)\b"#) else { return .init() }
        var result = MarkdownHTMLDocument(), offset = 0, ordinals: [String: Int] = [:]
        var fence: (marker: Character, count: Int, start: Int, body: Int, language: String)?
        func append(_ range: NSRange, body: NSRange) {
            let html = source.substring(with: body)
            let hash = NotebookProjectStore.digest(html)
            let ordinal = ordinals[hash, default: 0]; ordinals[hash] = ordinal + 1
            result.blocks.append(.init(range: range, source: html, id: hash + ":" + String(ordinal)))
        }
        while offset < source.length {
            let line = source.lineRange(for: NSRange(location: offset, length: 0))
            let value = source.substring(with: line).trimmingCharacters(in: .newlines)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let lineEnd = NSMaxRange(line)
            defer { if offset < lineEnd { offset = lineEnd } }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    let rest = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                    if let open = fence {
                        if marker == open.marker && count >= open.count && rest.isEmpty {
                            if open.language == "html-ui" || open.language == "notebook-ui" {
                                append(NSRange(location: open.start, length: lineEnd - open.start), body: NSRange(location: open.body, length: offset - open.body))
                            }
                            fence = nil
                        }
                    } else if !comments.contains(where: { NSLocationInRange(offset, $0) }) {
                        fence = (marker, count, offset, lineEnd, rest.lowercased())
                    }
                    continue
                }
            }
            guard fence == nil, !value.hasPrefix("\t"), value.prefix(while: { $0 == " " }).count <= 3,
                  !comments.contains(where: { NSLocationInRange(offset, $0) }),
                  let opening = tag.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
                  opening.range(at: 1).length == 0 else { continue }
            let root = (trimmed as NSString).substring(with: opening.range(at: 2)).lowercased()
            guard roots.contains(root) else { continue }
            var depth = 0, end: Int?
            tokens.enumerateMatches(in: text, range: NSRange(location: offset, length: source.length - offset)) { match, _, stop in
                guard let match else { return }
                let token = source.substring(with: match.range)
                guard let name = tag.firstMatch(in: token, range: NSRange(location: 0, length: token.utf16.count)),
                      (token as NSString).substring(with: name.range(at: 2)).lowercased() == root else { return }
                if root == "script" || root == "style" { end = NSMaxRange(match.range); stop.pointee = true; return }
                depth += name.range(at: 1).length == 0 ? 1 : -1
                if depth == 0 { end = NSMaxRange(match.range); stop.pointee = true }
            }
            guard let end else { continue } // Incomplete HTML stays visible and editable.
            let endingLine = source.lineRange(for: NSRange(location: end - 1, length: 0))
            guard source.substring(with: NSRange(location: end, length: NSMaxRange(endingLine) - end)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let range = NSRange(location: offset, length: NSMaxRange(endingLine) - offset)
            if root == "style" || root == "script" {
                if root == "style" { result.styles += source.substring(with: range) + "\n" }
                else { result.scripts += source.substring(with: range) + "\n" }
                result.supportRanges.append(range)
            } else {
                append(range, body: range)
            }
            offset = NSMaxRange(range)
        }
        return result
    }
}
