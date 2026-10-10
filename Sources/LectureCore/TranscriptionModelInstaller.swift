import Foundation
import CryptoKit

public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64
    public init(received: Int64, total: Int64) { self.received = received; self.total = total }
    public var fraction: Double { total > 0 ? min(1, max(0, Double(received) / Double(total))) : 0 }
}

/// One file download that reports how much has arrived. The file is moved
/// aside before the session deletes it; the caller removes it.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var file: URL?
    private var moveError: Error?
    private var reported = Date.distantPast
    init(expected: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) { self.expected = expected; self.progress = progress }

    static func run(_ url: URL, expected: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, URLResponse) {
        let delegate = ProgressDownload(expected: expected, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.lock(); delegate.continuation = continuation; delegate.lock.unlock()
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let due = Date().timeIntervalSince(reported) >= 0.1; if due { reported = Date() }; lock.unlock()
        if due { progress(.init(received: totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("palladium-download-" + UUID().uuidString)
        lock.lock(); defer { lock.unlock() }
        do { try FileManager.default.moveItem(at: location, to: kept); file = kept } catch { moveError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; let file = self.file, moveError = self.moveError; lock.unlock()
        if let error = error ?? moveError {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let file, let response = task.response {
            progress(.init(received: max(expected, task.countOfBytesReceived), total: max(expected, task.countOfBytesReceived)))
            continuation?.resume(returning: (file, response))
        } else { continuation?.resume(throwing: MediaError.invalid("Descarga de modelo fallida.")) }
    }
}

public struct TranscriptionModelInstaller: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    private func folder(_ name: String) throws -> URL {
        let target = root.appendingPathComponent(name)
        guard target.resolvingSymlinksInPath().path == target.standardizedFileURL.path else { throw MediaError.invalid("La carpeta de modelos no puede ser un enlace simbólico.") }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
    public func install(_ model: WhisperModel, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws {
        struct Repository: Decodable { struct File: Decodable { struct LFS: Decodable { let sha256: String; let size: Int64 }; let rfilename: String; let lfs: LFS? }; let sha: String; let siblings: [File] }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (metadata, response) = try await session.data(from: URL(string: "https://huggingface.co/api/models/ggerganov/whisper.cpp?blobs=true")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("No se pudo consultar el catálogo de Whisper.") }
        let repository = try JSONDecoder().decode(Repository.self, from: metadata)
        guard repository.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let file = repository.siblings.first(where: { $0.rfilename == model.filename }), let lfs = file.lfs,
              lfs.size > 1_000_000, lfs.size < 4_000_000_000 else { throw MediaError.invalid("Modelo no disponible en el catálogo oficial.") }
        let directory = try folder("models")
        progress(.init(received: 0, total: lfs.size))
        let (temporary, downloadResponse) = try await ProgressDownload.run(URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(repository.sha)/\(model.filename)")!, expected: lfs.size, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("Descarga de modelo fallida.") }
        try await Task.detached {
            let reader = try FileHandle(forReadingFrom: temporary); defer { try? reader.close() }
            var hash = SHA256(); var size: Int64 = 0
            while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data); size += Int64(data.count) }
            guard size == lfs.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == lfs.sha256 else { throw MediaError.invalid("La descarga no supera la verificación SHA-256.") }
        }.value
        try Task.checkCancellation()
        let staged = directory.appendingPathComponent(".download-" + UUID().uuidString)
        try FileManager.default.copyItem(at: temporary, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let destination = directory.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
    }
    public func uninstall(_ model: WhisperModel) throws {
        try FileManager.default.removeItem(at: folder("models").appendingPathComponent(model.filename))
    }
    public func installRuntime() async throws {
        let fm = FileManager.default
        guard let cmake = ["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake"].first(where: { fm.isExecutableFile(atPath: $0) }) else { throw MediaError.invalid("Instala CMake (brew install cmake) y las herramientas de Xcode para preparar Whisper.") }
        let directory = try folder("runtime")
        let stage = directory.appendingPathComponent("whisper-install-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let source = stage.appendingPathComponent("source"), build = stage.appendingPathComponent("build")
        try await run("/usr/bin/git", ["clone", "--depth", "1", "--branch", "v1.8.2", "https://github.com/ggml-org/whisper.cpp.git", source.path], directory: stage)
        try await run(cmake, ["-S", source.path, "-B", build.path, "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DWHISPER_BUILD_TESTS=OFF", "-DGGML_METAL_EMBED_LIBRARY=ON"], directory: stage)
        try await run(cmake, ["--build", build.path, "--config", "Release", "--target", "whisper-cli", "-j", "4"], directory: stage)
        try Task.checkCancellation()
        let target = directory.appendingPathComponent("whisper-build/bin")
        guard target.resolvingSymlinksInPath().path == target.standardizedFileURL.path else { throw MediaError.invalid("La carpeta del motor no puede ser un enlace simbólico.") }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let executable = target.appendingPathComponent("whisper-cli")
        if fm.fileExists(atPath: executable.path) { _ = try fm.replaceItemAt(executable, withItemAt: build.appendingPathComponent("bin/whisper-cli")) }
        else { try fm.moveItem(at: build.appendingPathComponent("bin/whisper-cli"), to: executable) }
    }
    public func installTeacherVoice() async throws {
        guard let python = ["/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.11", "/usr/local/bin/python3.12"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw MediaError.invalid("Instala Python 3.11 o 3.12 para usar la comparación local de voz.") }
        let runtime = try folder("runtime")
        let stage = runtime.appendingPathComponent("teacher-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        try await run(python, ["-m", "venv", stage.appendingPathComponent("venv").path], directory: stage)
        try await run(stage.appendingPathComponent("venv/bin/python").path, ["-m", "pip", "install", "--disable-pip-version-check", "sherpa-onnx==1.13.8", "numpy==2.4.4"], directory: stage)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx")!)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("No se pudo descargar el modelo de voz.") }
        let data = try Data(contentsOf: file)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == "5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94" else { throw MediaError.invalid("El modelo de voz no supera la verificación SHA-256.") }
        try data.write(to: stage.appendingPathComponent("model.onnx"))
        let (vad, vadResponse) = try await session.data(from: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!)
        guard (vadResponse as? HTTPURLResponse)?.statusCode == 200,
              SHA256.hash(data: vad).map({ String(format: "%02x", $0) }).joined() == "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6" else { throw MediaError.invalid("La descarga del detector de voz no supera la verificación.") }
        try vad.write(to: stage.appendingPathComponent("vad.onnx"))
        try Task.checkCancellation()
        let destination = runtime.appendingPathComponent("teacher-voice")
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: destination) }
    }
    public func uninstallTeacherVoice() throws {
        try FileManager.default.removeItem(at: folder("runtime").appendingPathComponent("teacher-voice"))
    }
    private func run(_ executable: String, _ arguments: [String], directory: URL) async throws {
        let command = LocalProcess(); command.process.executableURL = URL(fileURLWithPath: executable)
        command.process.arguments = arguments; command.process.currentDirectoryURL = directory
        command.process.standardOutput = FileHandle.nullDevice; command.process.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler { try await Task.detached { try command.run() }.value; try Task.checkCancellation() } onCancel: { command.cancel() }
    }
}
