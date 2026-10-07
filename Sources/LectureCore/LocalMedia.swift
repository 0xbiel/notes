import Foundation
import CryptoKit
@preconcurrency import AVFoundation

// AVFoundation's legacy exporter is not Sendable. Only its documented
// asynchronous export, progress and cancellation operations cross tasks here;
// configuration belongs to the single export operation.
private final class LocalExport: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    var progress: Double { Double(session.progress) }
    func cancel() { session.cancelExport() }
    func run(to url: URL) async throws {
        if #available(macOS 15.0, *) { try await session.export(to: url, as: .m4a) }
        else {
            session.outputURL = url; session.outputFileType = .m4a
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously { [self] in
                    if session.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: session.error ?? MediaError.invalid("Extracción interrumpida.")) }
                }
            }
        }
    }
}

public enum MediaStage: String, Codable, Sendable {
    case recording, copying, extracting, ready, transcribing, transcribed, interrupted, cancelled, failed, duplicate
    public var label: String {
        switch self {
        case .recording: "Grabando"
        case .copying: "Copiando"
        case .extracting: "Preparando audio"
        case .ready: "Listo"
        case .transcribing: "Transcribiendo"
        case .transcribed: "Transcrito"
        case .interrupted: "Interrumpido"
        case .cancelled: "Cancelado"
        case .failed: "No se pudo procesar"
        case .duplicate: "Ya importado"
        }
    }
}

public struct MediaTranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var boundaryReview: Bool? = nil
    public init(id: String, start: Double, end: Double, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text
    }
}

public struct MediaJob: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var importedAt = Date()
    public var classDate = Date()
    public var timezoneID = TimeZone.current.identifier
    public var notebookID: String
    public var subject: String
    public var targetNote: String
    public var sourceName: String
    public var inputMode: InputMode? = .lecture
    public var isMicrophone: Bool
    public var syntheticFixture = false
    public var unitTags: [String] = []
    public var examTags: [String] = []
    public var sourceRelativePath: String?
    public var audioRelativePath: String?
    public var sourceDigest: String?
    public var sourceCopyComplete = false
    public var duration = 0.0
    public var stage: MediaStage
    public var progress = 0.0
    public var error: String?
    public var duplicateOf: String?
    public var transcript: [MediaTranscriptSegment] = []
    public var completedChunks = 0
    public var live: LiveRecordingMetadata? = nil
    public var asrQualityWarning: String? = nil
    public init(notebookID: String, subject: String, note: String, sourceName: String, microphone: Bool = false) {
        self.notebookID = notebookID; self.subject = subject; targetNote = note
        self.sourceName = sourceName; isMicrophone = microphone
        stage = microphone ? .recording : .copying
    }
    public var dateFolder: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezoneID) ?? .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: importedAt)
    }
}

public enum MediaError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// File access is confined to session storage. Input is a user-selected local
/// regular file; no source bookmark, write or persistent external access is made.
public struct LocalMediaStore: Sendable {
    public let root: URL
    public let originalRoot: URL
    public var maximumBytes: UInt64 = 8 * 1024 * 1024 * 1024
    public var maximumDuration: Double = 8 * 60 * 60
    public init(workspace: SafeWorkspace) { root = workspace.root; originalRoot = workspace.originalRoot }
    private func workspace() throws -> SafeWorkspace { try SafeWorkspace(root: root, originalRoot: originalRoot) }
    public func url(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { throw MediaError.invalid("Ruta de medio rechazada.") }
        let workspace = try workspace()
        return try workspace.validated(workspace.storageRoot.appendingPathComponent(relative), under: workspace.storageRoot)
    }
    public func destination(for job: MediaJob, name: String) throws -> (relative: String, url: URL) {
        guard UUID(uuidString: job.id) != nil, !name.contains("/"), !name.hasPrefix(".") else { throw MediaError.invalid("Identificador de grabación inválido.") }
        let relative = "media/\(job.dateFolder)/\(job.id)/\(name)"
        let target = try url(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (relative, try url(relative))
    }
    public func save(_ job: MediaJob) throws {
        guard UUID(uuidString: job.id) != nil else { throw MediaError.invalid("Trabajo inválido.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try workspace().writeStorage("media-jobs/\(job.id).json", data: encoder.encode(job))
    }
    public func load() throws -> [MediaJob] {
        let workspace = try workspace()
        let folder = workspace.storageRoot.appendingPathComponent("media-jobs")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try entries.filter { $0.pathExtension == "json" }.map {
            let path = try workspace.validated($0, under: workspace.storageRoot)
            return try JSONDecoder().decode(MediaJob.self, from: Data(contentsOf: path))
        }.sorted { $0.importedAt > $1.importedAt }
    }
    public func recoverJobs() throws -> [MediaJob] {
        try load().map { item in
            var job = item
            if [.recording, .copying, .extracting, .transcribing].contains(job.stage) {
                job.stage = .interrupted; job.error = "El trabajo se interrumpió. Puedes reanudarlo desde la copia local; una copia incompleta requiere elegir la fuente otra vez."
                try save(job)
            }
            return job
        }
    }
    public func sourceSize(_ source: URL) throws -> UInt64 {
        guard source.isFileURL else { throw MediaError.invalid("Selecciona un archivo local.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MediaError.invalid("La fuente debe ser un archivo normal, sin enlaces.") }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size > 0, size <= maximumBytes else { throw MediaError.invalid("Archivo vacío o mayor que el límite de \(maximumBytes / 1024 / 1024) MB.") }
        return size
    }
    public func copySource(_ source: URL, into job: MediaJob, progress: @escaping @Sendable (Double) async -> Void) async throws -> (path: String, hash: String) {
        let size = try sourceSize(source)
        let sourceDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let suffix = source.pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "m4a", "mp3", "wav", "aif", "aiff", "caf", "flac", "aac"].contains(suffix) else { throw MediaError.invalid("Formato no compatible. Usa audio o MP4/MOV.") }
        let destination = try destination(for: job, name: "source-\(UUID().uuidString).\(suffix)")
        try Data().write(to: destination.url, options: .withoutOverwriting)
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: destination.url)
        defer { try? reader.close(); try? writer.close() }
        do {
            var hasher = SHA256(); var bytes: UInt64 = 0
            while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation(); bytes += UInt64(chunk.count)
                guard bytes <= maximumBytes else { throw MediaError.invalid("La fuente creció por encima del límite.") }
                hasher.update(data: chunk); try writer.write(contentsOf: chunk)
                await progress(min(1, Double(bytes) / Double(size)))
            }
            guard bytes == size, try sourceSize(source) == size, try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sourceDate else { throw MediaError.invalid("La fuente cambió mientras se copiaba; vuelve a elegirla.") }
            try writer.synchronize()
            return (destination.relative, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? FileManager.default.removeItem(at: url(destination.relative))
            throw error
        }
    }
    public func fingerprint(_ relative: String) throws -> String {
        let reader = try FileHandle(forReadingFrom: url(relative)); defer { try? reader.close() }
        var hasher = SHA256()
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func validateAudio(_ relative: String) async throws -> Double {
        let asset = AVURLAsset(url: try url(relative))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MediaError.invalid("El archivo no contiene una pista de audio compatible.") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= maximumDuration else { throw MediaError.invalid("Duración inválida o mayor que el límite de ocho horas.") }
        guard try await asset.load(.isPlayable) else { throw MediaError.invalid("El códec no es reproducible en este Mac.") }
        return duration
    }
    public func prepareAudio(for job: MediaJob, progress: @escaping @Sendable (Double) async -> Void) async throws -> (path: String, duration: Double) {
        guard job.sourceCopyComplete, let source = job.sourceRelativePath else { throw MediaError.invalid("Vuelve a seleccionar la fuente: la copia no está completa.") }
        let duration = try await validateAudio(source)
        if job.isMicrophone { return (source, duration) }
        let asset = AVURLAsset(url: try url(source))
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw MediaError.invalid("No se puede extraer el audio de este códec.") }
        let handle = LocalExport(export)
        let output = try destination(for: job, name: "audio-\(UUID().uuidString).m4a")
        let progressTask = Task {
            while !Task.isCancelled {
                await progress(handle.progress)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await handle.run(to: output.url)
                try Task.checkCancellation()
            } onCancel: { handle.cancel() }
            _ = try await validateAudio(output.relative)
            await progress(1)
            return (output.relative, duration)
        } catch {
            try? FileManager.default.removeItem(at: url(output.relative))
            throw error
        }
    }
    public func removeTemporary(_ relative: String) throws { try FileManager.default.removeItem(at: url(relative)) }
}
