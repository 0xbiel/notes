import Foundation

public enum MarkdownComments {
    /// Source ranges allow the editor to hide comments without deleting saved text.
    public static func ranges(in text: String) -> [NSRange] {
        let source = text as NSString
        let units = Array(text.utf16)
        var result: [NSRange] = [], index = 0
        var fence: (marker: UInt16, count: Int)?
        func has(_ value: String, at offset: Int) -> Bool {
            let wanted = Array(value.utf16)
            return offset + wanted.count <= units.count && units[offset..<offset + wanted.count].elementsEqual(wanted)
        }
        func escaped(_ offset: Int) -> Bool {
            var cursor = offset, count = 0
            while cursor > 0 && units[cursor - 1] == 92 { cursor -= 1; count += 1 }
            return count % 2 == 1
        }
        while index < units.count {
            if index == 0 || units[index - 1] == 10 {
                let line = source.lineRange(for: NSRange(location: index, length: 0))
                let end = NSMaxRange(line)
                var start = index
                while start < end && (units[start] == 32 || units[start] == 9) { start += 1 }
                if start < end && (units[start] == 96 || units[start] == 126) {
                    let marker = units[start]
                    var stop = start
                    while stop < end && units[stop] == marker { stop += 1 }
                    if let active = fence {
                        if marker == active.marker && stop - start >= active.count && source.substring(with: NSRange(location: stop, length: end - stop)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
                        index = end; continue
                    } else if stop - start >= 3 {
                        fence = (marker, stop - start); index = end; continue
                    }
                }
                if fence != nil { index = end; continue }
            }
            if !escaped(index), has("<!--", at: index) {
                let tail = NSRange(location: index + 4, length: units.count - index - 4)
                let closing = source.range(of: "-->", range: tail)
                let end = closing.location == NSNotFound ? units.count : NSMaxRange(closing)
                result.append(NSRange(location: index, length: end - index)); index = end; continue
            }
            if units[index] == 96 && !escaped(index) {
                var end = index
                while end < units.count && units[end] == 96 { end += 1 }
                let count = end - index
                var cursor = end, closing: Int?
                while cursor < units.count {
                    if units[cursor] == 96 {
                        let start = cursor
                        while cursor < units.count && units[cursor] == 96 { cursor += 1 }
                        if cursor - start == count { closing = cursor; break }
                    } else { cursor += 1 }
                }
                index = closing ?? end; continue
            }
            index += 1
        }
        return result
    }

    public static func removing(from text: String) -> String {
        let result = NSMutableString(string: text)
        for range in ranges(in: text).reversed() { result.replaceCharacters(in: range, with: "") }
        return result as String
    }
}
