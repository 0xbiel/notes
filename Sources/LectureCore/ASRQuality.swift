import Foundation

/// A review signal, not a correctness score: repeated decoder output is kept
/// verbatim and automatic note processing pauses instead of inventing fixes.
public enum ASRQuality {
    public static func repetitionWarning(_ segments: [MediaTranscriptSegment]) -> String? {
        var counts: [String: Int] = [:]
        for segment in segments {
            let tokens = segment.text.lowercased().split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            let key = tokens.joined(separator: " ")
            if !tokens.isEmpty {
                counts[key, default: 0] += 1
                if counts[key, default: 0] >= 4 { return warning }
            }
            // Also catch a repeated phrase packed into a single ASR segment.
            if tokens.count >= 16 {
                for period in 4...min(40, tokens.count / 4) {
                    for start in 0...(tokens.count - period * 4) {
                        let phrase = Array(tokens[start..<(start + period)])
                        if (1..<4).allSatisfy({ repeatIndex in Array(tokens[(start + repeatIndex * period)..<(start + (repeatIndex + 1) * period)]) == phrase }) { return warning }
                    }
                }
            }
        }
        return nil
    }
    private static let warning = "Whisper ha repetido frases. Revisa el audio y la transcripción antes de usarla para notas; el envío automático se ha pausado."
}
