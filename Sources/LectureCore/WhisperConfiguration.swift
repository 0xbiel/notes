import Foundation

public enum WhisperModel: String, Codable, CaseIterable, Sendable {
    case small
    case largeV3Turbo
    case medium
    public var displayName: String {
        switch self {
        case .small: "Whisper small"
        case .largeV3Turbo: "Whisper large-v3-turbo"
        case .medium: "Whisper medium"
        }
    }
    public var filename: String {
        switch self {
        case .small: "ggml-small.bin"
        case .largeV3Turbo: "ggml-large-v3-turbo.bin"
        case .medium: "ggml-medium.bin"
        }
    }
}

/// Persisted per recording so recovery cannot reinterpret existing chunk IDs
/// after an ASR policy change. No configuration path installs or fetches models.
public struct WhisperConfiguration: Codable, Equatable, Sendable {
    public var model: WhisperModel
    public var importChunkSeconds: Double
    public var conditionOnPreviousText: Bool
    public init(model: WhisperModel = .small, importChunkSeconds: Double = 30, conditionOnPreviousText: Bool = false) {
        self.model = model; self.importChunkSeconds = importChunkSeconds; self.conditionOnPreviousText = conditionOnPreviousText
    }
    public static func resolved(for job: MediaJob) throws -> Self {
        // Legacy checkpoints counted five-minute chunks. Preserve their layout,
        // while disabling further decoder-history feedback on future chunks.
        let value = job.whisperConfiguration ?? Self(importChunkSeconds: job.live == nil && job.completedChunks > 0 ? 300 : 30)
        guard value.importChunkSeconds.isFinite, value.importChunkSeconds >= 10, value.importChunkSeconds <= 300 else { throw MediaError.invalid("Configuración de Whisper inválida.") }
        return value
    }
    /// Identical audio can share its preparation across configurations, but
    /// transcript IDs/checkpoint counts only share an identical decoding policy.
    public static func canReuseTranscript(from source: MediaJob, for destination: MediaJob) -> Bool {
        // A legacy job has no reliable record of the original decoder policy.
        guard source.whisperConfiguration != nil, destination.whisperConfiguration != nil,
              let sourceConfiguration = try? resolved(for: source),
              let destinationConfiguration = try? resolved(for: destination) else { return false }
        return sourceConfiguration == destinationConfiguration
    }
    public func arguments(model: URL, audio: URL, output: URL) -> [String] {
        var values = ["-m", model.path, "-f", audio.path, "-l", "es", "-t", "6", "-oj", "-of", output.path, "-sns"]
        if !conditionOnPreviousText { values += ["-mc", "0"] }
        return values
    }
}
