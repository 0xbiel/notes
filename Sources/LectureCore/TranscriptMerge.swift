import Foundation

public enum TranscriptMerge {
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }
    /// Exact overlap words may be removed; conflicting boundary hypotheses are
    /// retained and marked for review rather than discarding a negation/correction.
    public static func append(_ incoming: [MediaTranscriptSegment], to existing: [MediaTranscriptSegment]) -> [MediaTranscriptSegment] {
        var result = existing; var ids = Set(existing.map(\.id))
        for var segment in incoming.sorted(by: { $0.start < $1.start }) where !ids.contains(segment.id) {
            let recent = result.suffix(3)
            let normalized = words(segment.text)
            guard !normalized.isEmpty else { continue }
            if recent.contains(where: { abs($0.end - segment.end) <= 2.5 && words($0.text) == normalized }) { continue }
            if let last = result.last, segment.start < last.end {
                let previous = words(recent.map(\.text).joined(separator: " "))
                var common = 0
                let maximum = min(40, previous.count, normalized.count)
                if maximum >= 3 {
                    for count in (3...maximum).reversed() where Array(previous.suffix(count)) == Array(normalized.prefix(count)) { common = count; break }
                }
                if common == normalized.count { continue }
                if common >= 3 {
                    let originalWords = segment.text.split(whereSeparator: \.isWhitespace)
                    segment.text = originalWords.dropFirst(common).joined(separator: " ")
                    segment.start = min(segment.end, max(last.end, segment.start))
                } else { segment.boundaryReview = true }
            }
            result.append(segment); ids.insert(segment.id)
        }
        return result
    }
}
