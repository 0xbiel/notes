import Foundation

public struct LiveAudioChunk: Codable, Identifiable, Sendable {
    public var index: Int
    public var path: String
    public var start: Double
    public var end: Double
    public var digest: String
    public var id: Int { index }
}
public struct LiveCaptureManifest: Codable, Sendable {
    public var version = 1
    public var mediaID: String
    public var source: String
    public var frames: UInt64
    public var closed: Bool
    public var chunks: [LiveAudioChunk]
    public var duration: Double { Double(frames) / 16_000 }
}
public struct LiveRecordingMetadata: Codable, Sendable {
    public var sealedChunks: Int = 0
    public var processedChunks: Int = 0
    public var captureEnded = false
    public var backlog: Int { max(0, sealedChunks - processedChunks) }
    public init() { }
}

private final class PCMFile {
    let handle: FileHandle
    var frames: UInt64 = 0
    init(url: URL) throws {
        try RollingPCMRecorder.header(frames: 0).write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    }
    func append(_ data: Data) throws { try handle.write(contentsOf: data); frames += UInt64(data.count / 2) }
    func checkpoint() throws {
        try handle.seek(toOffset: 0); try handle.write(contentsOf: RollingPCMRecorder.header(frames: frames)); try handle.seekToEnd(); try handle.synchronize()
    }
    func close() throws { try checkpoint(); try handle.close() }
}

/// Continuous 16kHz mono PCM16 recording, independent of hardware. Full audio
/// is never cut at recognition boundaries. Sealed 30s clips overlap by2s;
/// only tiny input buffers and the64KB overlap remain in memory.
public final class RollingPCMRecorder: @unchecked Sendable {
    public static let secondsPerChunk = 30.0
    public static let overlapSeconds = 2.0
    public static let maximumPendingInference = 8
    public let store: LocalMediaStore
    public let job: MediaJob
    public let maximumFrames: UInt64
    public let sourcePath: String
    private let lock = NSLock()
    private let full: PCMFile
    private var current: PCMFile?
    private var currentPath: String?
    private var freshFrames: UInt64 = 0
    private var tail = Data()
    private var state: LiveCaptureManifest
    public init(store: LocalMediaStore, job: MediaJob) throws {
        guard store.maximumDuration > 0, store.maximumDuration <= 28_800 else { throw MediaError.invalid("Límite de captura inválido.") }
        self.store = store; self.job = job
        maximumFrames = min(UInt64(store.maximumDuration * 16_000), (store.maximumBytes > 44 ? store.maximumBytes - 44 : 0) / 2)
        guard maximumFrames > 0 else { throw MediaError.invalid("No hay capacidad para guardar audio.") }
        let source = try store.destination(for: job, name: "live-source.wav")
        sourcePath = source.relative; full = try PCMFile(url: source.url)
        state = LiveCaptureManifest(mediaID: job.id, source: source.relative, frames: 0, closed: false, chunks: [])
        try openChunk(); try persist()
    }
    public var snapshot: LiveCaptureManifest { lock.lock(); defer { lock.unlock() }; return state }
    public func appendPCM16(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !state.closed, !data.isEmpty, data.count % 2 == 0, data.count <= 65_536 else { throw MediaError.invalid("Buffer PCM vacío, demasiado grande o captura cerrada.") }
        let remaining = maximumFrames - state.frames
        let accepted = data.prefix(Int(min(UInt64(data.count / 2), remaining) * 2))
        if !accepted.isEmpty { try full.append(Data(accepted)) }
        var position = 0
        while position < accepted.count {
            let free = UInt64(Self.secondsPerChunk * 16_000) - freshFrames
            let bytes = min(accepted.count - position, Int(free * 2))
            let piece = Data(accepted[position..<(position + bytes)])
            try current?.append(piece); freshFrames += UInt64(bytes / 2); state.frames += UInt64(bytes / 2)
            tail.append(piece); if tail.count > 64_000 { tail = Data(tail.suffix(64_000)) }
            position += bytes
            if freshFrames == UInt64(Self.secondsPerChunk * 16_000) { try sealChunk(); try full.checkpoint(); try persist(); try openChunk() }
        }
        if state.frames >= maximumFrames { try finishLocked(); throw MediaError.invalid("Captura detenida al alcanzar el límite de duración o almacenamiento; el audio guardado se conserva.") }
    }
    @discardableResult public func finish() throws -> LiveCaptureManifest {
        lock.lock(); defer { lock.unlock() }
        if !state.closed { try finishLocked() }; return state
    }
    private func openChunk() throws {
        let target = try store.destination(for: job, name: String(format: "live-%04d.wav", state.chunks.count))
        current = try PCMFile(url: target.url); currentPath = target.relative; freshFrames = 0
        if !state.chunks.isEmpty { try current?.append(tail) }
    }
    private func sealChunk() throws {
        guard let current, let path = currentPath, freshFrames > 0 else { return }
        try current.close()
        let duration = Double(current.frames) / 16_000
        state.chunks.append(LiveAudioChunk(index: state.chunks.count, path: path, start: max(0, state.duration - duration), end: state.duration, digest: try store.fingerprint(path)))
        self.current = nil; currentPath = nil; freshFrames = 0
        guard state.chunks.count <= 961 else { throw MediaError.invalid("Demasiados fragmentos de audio.") }
    }
    private func finishLocked() throws {
        if freshFrames > 0 { try sealChunk() }
        else if let current, let currentPath { try current.close(); try store.removeTemporary(currentPath); self.current = nil; self.currentPath = nil }
        try full.close(); state.closed = true; try persist()
    }
    private func persist() throws {
        let target = try store.destination(for: job, name: "live-manifest.json")
        let workspace = try SafeWorkspace(root: store.root, originalRoot: store.originalRoot)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try workspace.writeStorage(target.relative, data: encoder.encode(state))
    }
    public static func header(frames: UInt64) -> Data {
        precondition(frames <= (UInt64(UInt32.max) - 36) / 2)
        var result = Data()
        func string(_ value: String) { result.append(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        string("RIFF"); number(UInt32(frames * 2 + 36)); string("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000)); number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16)); string("data"); number(UInt32(frames * 2)); return result
    }
    public static func load(store: LocalMediaStore, job: MediaJob) throws -> LiveCaptureManifest {
        let target = try store.destination(for: job, name: "live-manifest.json")
        let state = try JSONDecoder().decode(LiveCaptureManifest.self, from: Data(contentsOf: target.url))
        let source = try store.destination(for: job, name: "live-source.wav")
        guard state.version == 1, state.mediaID == job.id, state.source == source.relative, state.duration <= store.maximumDuration, state.chunks.count <= 961 else { throw MediaError.invalid("Estado de captura inválido.") }
        for (index, chunk) in state.chunks.enumerated() {
            let expected = try store.destination(for: job, name: String(format: "live-%04d.wav", index))
            guard chunk.index == index, chunk.path == expected.relative, chunk.start.isFinite, chunk.end.isFinite, chunk.start >= 0, chunk.end > chunk.start, chunk.end - chunk.start <= 32.01 else { throw MediaError.invalid("Fragmento de captura inválido.") }
        }
        return state
    }
    /// Explicit user recovery only: repair our own PCM header from its bounded
    /// physical length and reconstruct the final unsealed tail. Never imports.
    public static func recover(store: LocalMediaStore, job: MediaJob) throws -> LiveCaptureManifest {
        var state = try load(store: store, job: job)
        guard !state.closed else { return state }
        let source = try store.url(state.source)
        let size = try store.sourceSize(source)
        guard size >= 44, (size - 44) % 2 == 0, Double((size - 44) / 2) / 16_000 <= store.maximumDuration else { throw MediaError.invalid("Captura PCM incompleta o fuera del límite.") }
        let reader = try FileHandle(forReadingFrom: source); let existing = try reader.read(upToCount: 44); try reader.close()
        let expected = header(frames: 0)
        guard let existing, existing.count == 44, existing[0..<4] == expected[0..<4], existing[8..<40] == expected[8..<40] else { throw MediaError.invalid("No es la captura PCM generada por esta app.") }
        state.frames = (size - 44) / 2
        let writer = try FileHandle(forWritingTo: source); try writer.write(contentsOf: header(frames: state.frames)); try writer.close()
        let processedBoundary = state.chunks.last?.end ?? 0
        if state.duration > processedBoundary + 0.0001 {
            let target = try store.destination(for: job, name: String(format: "live-%04d.wav", state.chunks.count))
            if FileManager.default.fileExists(atPath: target.url.path) { try store.removeTemporary(target.relative) }
            let start = max(0, processedBoundary - (state.chunks.isEmpty ? 0 : 2))
            guard state.duration - start <= 32.01 else { throw MediaError.invalid("La captura recuperada supera un fragmento pendiente.") }
            try WhisperTranscriber.convertPCM(source: source, output: target.url, offset: start, duration: state.duration - start)
            state.chunks.append(.init(index: state.chunks.count, path: target.relative, start: start, end: state.duration, digest: try store.fingerprint(target.relative)))
        }
        state.closed = true
        let target = try store.destination(for: job, name: "live-manifest.json")
        let workspace = try SafeWorkspace(root: store.root, originalRoot: store.originalRoot)
        try workspace.writeStorage(target.relative, data: JSONEncoder().encode(state)); return state
    }
}
