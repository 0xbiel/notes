import Foundation
@preconcurrency import AVFoundation

private final class LocalProcess: @unchecked Sendable {
    let process = Process()
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

    /// A bounded five-minute PCM chunk keeps long lectures out of RAM. The two
    /// second overlap supplies context; completed chunks are checkpointed.
    public func transcribe(_ original: MediaJob, checkpoint: @escaping @Sendable (MediaJob) async throws -> Void) async throws -> MediaJob {
        guard available, let audio = original.audioRelativePath else { throw MediaError.invalid("Falta el motor local o el audio preparado.") }
        var job = original; job.stage = .transcribing; job.error = nil
        let count = Int(ceil(job.duration / 300))
        guard count > 0, count <= Int(ceil(store.maximumDuration / 300)), job.completedChunks >= 0, job.completedChunks <= count else { throw MediaError.invalid("Duración de grabación inválida.") }
        for index in job.completedChunks..<count {
            try Task.checkCancellation()
            let boundary = Double(index) * 300
            let offset = max(0, boundary - (index == 0 ? 0 : 2))
            let duration = min(job.duration - offset, 300 + (index == 0 ? 0 : 2))
            let wav = try store.destination(for: job, name: "chunk-\(index).wav")
            if FileManager.default.fileExists(atPath: wav.url.path) { try store.removeTemporary(wav.relative) }
            try Self.convertPCM(source: store.url(audio), output: wav.url, offset: offset, duration: duration)
            let base = try store.destination(for: job, name: "asr-\(index)-\(UUID().uuidString)")
            let resultPath = base.relative + ".json"
            _ = try store.url(resultPath)
            let log = try store.destination(for: job, name: "asr-\(index)-\(UUID().uuidString).log")
            try Data().write(to: log.url, options: .withoutOverwriting)
            let logHandle = try FileHandle(forWritingTo: log.url)
            let command = LocalProcess()
            command.process.executableURL = binary
            command.process.arguments = ["-m", model.path, "-f", wav.url.path, "-l", "es", "-t", "6", "-oj", "-of", base.url.path, "-sns"]
            command.process.currentDirectoryURL = store.root
            command.process.standardOutput = logHandle; command.process.standardError = logHandle
            do {
                try await withTaskCancellationHandler {
                    try await Task.detached { try command.run() }.value
                    try Task.checkCancellation()
                } onCancel: { command.cancel() }
                try logHandle.close()
                let segments = try Self.decode(Data(contentsOf: store.url(resultPath)), offset: offset, chunk: index)
                if let warning = ASRQuality.repetitionWarning(segments) { job.asrQualityWarning = warning; job.error = warning }
                job.transcript = TranscriptMerge.append(segments, to: job.transcript)
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
        guard available, chunk.index >= 0, chunk.index <= 960, chunk.start >= 0, chunk.end > chunk.start, chunk.end - chunk.start <= 32.01,
              try store.fingerprint(chunk.path) == chunk.digest else { throw MediaError.invalid("Fragmento en directo inválido o modificado.") }
        let base = try store.destination(for: job, name: "live-asr-\(chunk.index)-\(UUID().uuidString)")
        let log = try store.destination(for: job, name: "live-asr-\(chunk.index)-\(UUID().uuidString).log")
        try Data().write(to: log.url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: log.url); defer { try? handle.close() }
        let command = LocalProcess(); command.process.executableURL = binary
        command.process.arguments = ["-m", model.path, "-f", try store.url(chunk.path).path, "-l", "es", "-t", "6", "-oj", "-of", base.url.path, "-sns"]
        command.process.currentDirectoryURL = store.root; command.process.standardOutput = handle; command.process.standardError = handle
        try await withTaskCancellationHandler {
            try await Task.detached { try command.run() }.value; try Task.checkCancellation()
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

    public static func convertPCM(source: URL, output: URL, offset: Double = 0, duration: Double = 300) throws {
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
        let file = try AVAudioFile(forWriting: output, settings: outputFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: converted); try Task.checkCancellation()
    }
}
