import Foundation

/// Splits a 16 kHz mono PCM16 stream into utterances at the speaker's pauses.
/// Segments never overlap and silence is never emitted, so recognition sees
/// whole phrases: no word is cut at a boundary or heard twice.
public struct VoiceSegmenter: Sendable {
    public struct Segment: Equatable, Sendable {
        /// Position of the first sample in the stream.
        public var start: UInt64
        public var samples: Data
        public var frames: UInt64 { UInt64(samples.count / 2) }
    }
    /// 20 ms analysis frames.
    static let frame = 320
    static let preRoll = 15, minimumVoiced = 8, pause = 30, shortPause = 12
    /// A word or two is recognised badly alone: it waits this long for the next phrase to join it.
    static let briefVoiced = 50, briefPause = 100
    static let relaxAfter = 750, maximum = 1400

    private var residual = Data()
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    private var position: UInt64 = 0
    private var floor = 0.0
    private var voiced = 0
    private var quiet = 0
    private var lastSpeech: UInt64 = 0
    public private(set) var heardSpeech = false
    public init() { }

    /// Seconds since the last speech, or since the start when none was heard.
    public var silentSeconds: Double { Double(position - (heardSpeech ? lastSpeech : 0)) / 16_000 }

    static func level(_ frame: Data) -> Double {
        frame.withUnsafeBytes { raw in
            var sum = 0.0
            for index in stride(from: 0, to: raw.count - 1, by: 2) {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: Int16.self))) / 32_768
                sum += sample * sample
            }
            return (sum / Double(max(1, raw.count / 2))).squareRoot()
        }
    }

    public mutating func append(_ data: Data) -> [Segment] {
        residual.append(data)
        var segments: [Segment] = []
        let size = Self.frame * 2
        var offset = residual.startIndex
        while residual.endIndex - offset >= size {
            let frame = residual[offset..<(offset + size)]
            offset += size
            if let segment = consume(frame) { segments.append(segment) }
        }
        residual = Data(residual[offset...])
        return segments
    }

    private mutating func consume(_ frame: Data) -> Segment? {
        let level = Self.level(frame)
        // The floor follows room noise down at once and up slowly, so speech does not raise it.
        if position == 0 { floor = level } else { floor = level < floor ? floor * 0.7 + level * 0.3 : floor * 0.9995 + level * 0.0005 }
        let speaking = level > min(0.03, max(0.0035, floor * 3))
        buffer.append(frame); position += UInt64(Self.frame)
        if speaking { voiced += 1; quiet = 0 } else { quiet += 1 }
        if speaking, voiced >= Self.minimumVoiced { heardSpeech = true; lastSpeech = position }
        let frames = buffer.count / (Self.frame * 2)
        if voiced < Self.minimumVoiced {
            // Nothing said yet, or only a click: keep a short lead-in and wait.
            if quiet >= Self.pause || voiced == 0 { voiced = 0; trim(to: Self.preRoll) }
            return nil
        }
        let needed = voiced < Self.briefVoiced ? Self.briefPause : (frames >= Self.relaxAfter ? Self.shortPause : Self.pause)
        guard quiet >= needed || frames >= Self.maximum else { return nil }
        return take()
    }

    private mutating func trim(to frames: Int) {
        let excess = buffer.count - frames * Self.frame * 2
        guard excess > 0 else { return }
        buffer = Data(buffer.suffix(frames * Self.frame * 2)); bufferStart += UInt64(excess / 2)
    }

    private mutating func take() -> Segment {
        let segment = Segment(start: bufferStart, samples: buffer)
        buffer = Data(); bufferStart = position; voiced = 0; quiet = 0
        return segment
    }

    /// The utterance still open when capture ends, if anything was said in it.
    public mutating func finish() -> Segment? {
        guard voiced >= Self.minimumVoiced else { return nil }
        buffer.append(residual.prefix(residual.count / 2 * 2)); residual = Data()
        return take()
    }
}
