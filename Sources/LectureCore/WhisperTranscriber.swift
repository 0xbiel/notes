import Foundation
@preconcurrency import AVFoundation

final class LocalProcess: @unchecked Sendable {
    let process = Process()
    init() {
        process.qualityOfService = .utility
        process.environment = ProcessInfo.processInfo.environment.merging(["VECLIB_MAXIMUM_THREADS": "2", "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2"]) { _, new in new }
    }
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; if process.isRunning { process.terminate() }; lock.unlock() }
    func run() throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MediaError.invalid("Whisper terminó con error. La grabación y los fragmentos anteriores siguen guardados.") }
    }
}

public struct WhisperTranscriber: Sendable {
    public let store: LocalMediaStore
    private let runtimeRoot: URL
    public init(store: LocalMediaStore, runtimeRoot: URL? = nil) { self.store = store; self.runtimeRoot = runtimeRoot ?? store.root }
    public var binary: URL { runtimeRoot.appendingPathComponent("runtime/whisper-build/bin/whisper-cli") }
    public var model: URL { runtimeRoot.appendingPathComponent("models/ggml-small.bin") }
    public var available: Bool { FileManager.default.isExecutableFile(atPath: binary.path) && FileManager.default.fileExists(atPath: model.path) }
    public func model(for configuration: WhisperConfiguration) -> URL { runtimeRoot.appendingPathComponent("models/" + configuration.model.filename) }
    public func available(for configuration: WhisperConfiguration) -> Bool { FileManager.default.isExecutableFile(atPath: binary.path) && FileManager.default.fileExists(atPath: model(for: configuration).path) }
    /// Choose only an already installed model. Existing jobs keep their saved
    /// policy; no startup/model choice performs a download or provider request.
    public var preferredConfiguration: WhisperConfiguration {
        let turbo = WhisperConfiguration(model: .largeV3Turbo)
        return available(for: turbo) ? turbo : WhisperConfiguration()
    }

    /// New imports use independent 30s windows and 2s audio overlap. Persisted
    /// legacy checkpoints retain their original layout when explicitly resumed.
    public func transcribe(_ original: MediaJob, checkpoint: @escaping @Sendable (MediaJob) async throws -> Void) async throws -> MediaJob {
        let configuration = try WhisperConfiguration.resolved(for: original)
        guard (original.transcriptionProvider == .openAI || available(for: configuration)), let audio = original.audioRelativePath else { throw MediaError.invalid("Falta el modelo local seleccionado o el audio preparado. No se descarga ni envía nada automáticamente.") }
        if original.teacherReference != nil, !TeacherVoiceMatcher(store: store).available { throw MediaError.invalid("Instala la comparación de voz o quita la referencia del profesor antes de transcribir.") }
        var job = original; job.stage = .transcribing; job.error = nil
        job.whisperConfiguration = configuration
        let seconds = configuration.importChunkSeconds
        guard job.duration.isFinite, job.duration > 0, job.duration <= store.maximumDuration else { throw MediaError.invalid("Duración de grabación inválida.") }
        let count = Int(ceil(job.duration / seconds))
        guard count > 0, count <= Int(ceil(store.maximumDuration / seconds)), job.completedChunks >= 0, job.completedChunks <= count else { throw MediaError.invalid("Duración de grabación inválida.") }
        for index in job.completedChunks..<count {
            try Task.checkCancellation()
            let boundary = Double(index) * seconds
            let offset = max(0, boundary - (index == 0 ? 0 : 2))
            let duration = min(job.duration - offset, seconds + (index == 0 ? 0 : 2))
            let wav = try store.destination(for: job, name: "chunk-\(index).wav")
            if FileManager.default.fileExists(atPath: wav.url.path) { try store.removeTemporary(wav.relative) }
            try Self.convertPCM(source: store.url(audio), output: wav.url, offset: offset, duration: duration, normalize: configuration.normalizeAudio == true)
            let base = try store.destination(for: job, name: "asr-\(index)-\(UUID().uuidString)")
            let resultPath = base.relative + ".json"
            _ = try store.url(resultPath)
            let log = try store.destination(for: job, name: "asr-\(index)-\(UUID().uuidString).log")
            try Data().write(to: log.url, options: .withoutOverwriting)
            let logHandle = try FileHandle(forWritingTo: log.url)
            let command = LocalProcess()
            command.process.executableURL = binary
            command.process.arguments = configuration.arguments(model: model(for: configuration), audio: wav.url, output: base.url, language: job.transcriptionLanguage ?? "es")
            command.process.currentDirectoryURL = store.root
            command.process.standardOutput = logHandle; command.process.standardError = logHandle
            do {
                var segments: [MediaTranscriptSegment]
                if job.transcriptionProvider == .openAI {
                    segments = try await APIAudioTranscriber().transcribe(audio: wav.url, offset: offset, duration: duration, chunk: index, language: job.transcriptionLanguage ?? "es")
                } else {
                    try await withTaskCancellationHandler {
                        try await Task.detached(priority: .utility) { try command.run() }.value
                        try Task.checkCancellation()
                    } onCancel: { command.cancel() }
                    segments = try Self.decode(Data(contentsOf: store.url(resultPath)), offset: offset, chunk: index)
                }
                if let reference = job.teacherReference {
                    segments = try await TeacherVoiceMatcher(store: store).annotate(segments, audio: wav.url, offset: offset, reference: reference)
                }
                try logHandle.close()
                if let warning = ASRQuality.repetitionWarning(segments) { job.asrQualityWarning = warning; job.error = warning }
                job.transcript = TranscriptMerge.append(segments, to: job.transcript)
                if let warning = ASRQuality.repetitionWarning(job.transcript) { job.asrQualityWarning = warning; job.error = warning }
                job.completedChunks = index + 1; job.progress = Double(index + 1) / Double(count)
                try store.save(job); try await checkpoint(job)
                try? store.removeTemporary(wav.relative)
            } catch {
                try? logHandle.close(); try? store.removeTemporary(wav.relative)
                throw error
            }
        }
        job.stage = .transcribed; job.progress = 1; try store.save(job); try await checkpoint(job)
        return job
    }

    public func transcribeLiveChunk(_ chunk: LiveAudioChunk, job: MediaJob) async throws -> [MediaTranscriptSegment] {
        let configuration = try WhisperConfiguration.resolved(for: job)
        guard (job.transcriptionProvider == .openAI || available(for: configuration)), chunk.index >= 0, chunk.index <= 5760, chunk.start.isFinite, chunk.end.isFinite, chunk.start >= 0, chunk.end > chunk.start, chunk.end - chunk.start <= 32.01,
              try store.fingerprint(chunk.path) == chunk.digest else { throw MediaError.invalid("Fragmento en directo inválido o modificado.") }
        let normalized = try store.destination(for: job, name: "live-level-\(UUID().uuidString).wav")
        defer { try? store.removeTemporary(normalized.relative) }
        let audio: URL
        if configuration.normalizeAudio == true {
            try Self.convertPCM(source: store.url(chunk.path), output: normalized.url, duration: chunk.end - chunk.start, normalize: true)
            audio = normalized.url
        } else { audio = try store.url(chunk.path) }
        if job.transcriptionProvider == .openAI {
            return try await APIAudioTranscriber().transcribe(audio: audio, offset: chunk.start, duration: chunk.end - chunk.start, chunk: chunk.index, language: job.transcriptionLanguage ?? "es")
        }
        let base = try store.destination(for: job, name: "live-asr-\(chunk.index)-\(UUID().uuidString)")
        let log = try store.destination(for: job, name: "live-asr-\(chunk.index)-\(UUID().uuidString).log")
        try Data().write(to: log.url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: log.url); defer { try? handle.close() }
        let command = LocalProcess(); command.process.executableURL = binary
        command.process.arguments = configuration.arguments(model: model(for: configuration), audio: audio, output: base.url, language: job.transcriptionLanguage ?? "es")
        command.process.currentDirectoryURL = store.root; command.process.standardOutput = handle; command.process.standardError = handle
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try command.run() }.value; try Task.checkCancellation()
        } onCancel: { command.cancel() }
        guard try store.fingerprint(chunk.path) == chunk.digest else { throw MediaError.invalid("El audio cambió durante la transcripción.") }
        return try Self.decode(Data(contentsOf: store.url(base.relative + ".json")), offset: chunk.start, chunk: chunk.index)
            .filter { $0.start <= chunk.end + 0.25 && $0.end <= chunk.end + 0.5 }
    }

    public static func decode(_ data: Data, offset: Double, chunk: Int) throws -> [MediaTranscriptSegment] {
        struct Result: Decodable { var transcription: [Segment] }
        struct Segment: Decodable { struct Offsets: Decodable { var from: Double; var to: Double }; var offsets: Offsets; var text: String }
        return try JSONDecoder().decode(Result.self, from: data).transcription.enumerated().compactMap { index, item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, item.offsets.from.isFinite, item.offsets.to.isFinite, item.offsets.to >= item.offsets.from else { return nil }
            return MediaTranscriptSegment(id: "\(chunk)-\(index)", start: offset + item.offsets.from / 1000, end: offset + item.offsets.to / 1000, text: text)
        }
    }

    public static func convertPCM(source: URL, output: URL, offset: Double = 0, duration: Double = 300, normalize: Bool = false) throws {
        try Task.checkCancellation()
        guard offset >= 0, duration > 0, duration <= 302 else { throw MediaError.invalid("Fragmento de audio inválido.") }
        let input = try AVAudioFile(forReading: source)
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount <= 8 else { throw MediaError.invalid("Formato de audio no admitido.") }
        let position = AVAudioFramePosition(offset * inputFormat.sampleRate)
        guard position < input.length else { throw MediaError.invalid("Fragmento fuera de la grabación.") }
        input.framePosition = position
        let frames = min(input.length - position, AVAudioFramePosition(duration * inputFormat.sampleRate))
        guard frames <= AVAudioFramePosition(UInt32.max), let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(frames) * 16_000 / inputFormat.sampleRate + 256)) else { throw MediaError.invalid("No se pudo convertir el audio.") }
        try input.read(into: buffer)
        var supplied = false; var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard error == nil, status != .error, converted.frameLength > 0 else { throw error ?? MediaError.invalid("Conversión de audio vacía.") }
        if normalize, let samples = converted.int16ChannelData?[0] {
            SpeechAudioLevel.normalize(UnsafeMutableBufferPointer(start: samples, count: Int(converted.frameLength)))
        }
        let file = try AVAudioFile(forWriting: output, settings: outputFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: converted); try Task.checkCancellation()
    }
}
