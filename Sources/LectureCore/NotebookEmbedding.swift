import Foundation
import CryptoKit

/// Turns text and pictures into vectors that can be compared.
public protocol NotebookEmbedder: Sendable {
    func embed(texts: [String]) async throws -> [[Float]]
    func embed(image: Data) async throws -> [Float]
}

/// EmbeddingGemma 2 on this Mac, through a prebuilt llama.cpp server. The runtime and the
/// model are downloaded once and checked against pinned SHA-256 values; nothing embedded
/// leaves the machine.
public struct NotebookEmbeddingRuntime: Sendable {
    struct Asset: Sendable { let name: String; let url: String; let size: Int64; let sha256: String }
    static let build = "llama-b11588"
    static let archive = Asset(name: "llama.tar.gz", url: "https://github.com/ggml-org/llama.cpp/releases/download/b11588/llama-b11588-bin-macos-arm64.tar.gz",
                               size: 12_112_245, sha256: "95039180209cb8b9a2fadedd03e061c5131fed17e1eb423b3dcf8c7848d12b9d")
    private static let repository = "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/"
    static let textModel = Asset(name: "embeddinggemma-2-Q8_0.gguf", url: repository + "embeddinggemma-2-Q8_0.gguf",
                                 size: 309_855_456, sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    static let visionModel = Asset(name: "mmproj-embeddinggemma-2-Q8_0.gguf", url: repository + "mmproj-embeddinggemma-2-Q8_0.gguf",
                                   size: 554_821_024, sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    /// Vectors are cut to this Matryoshka size, which stays close to the full 768 and makes an index a third as large.
    public static let dimensions = 256
    /// An index made with another model or size is rebuilt.
    public static let identity = "embeddinggemma-2-Q8_0/\(dimensions)"
    public static var downloadSize: Int64 { archive.size + textModel.size + visionModel.size }
    public static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("embedding", isDirectory: true) }
    var server: URL { root.appendingPathComponent("runtime/\(Self.build)/llama-server") }
    var text: URL { root.appendingPathComponent("models/" + Self.textModel.name) }
    var vision: URL { root.appendingPathComponent("models/" + Self.visionModel.name) }
    var log: URL { root.appendingPathComponent("server.log") }
    var pidFile: URL { root.appendingPathComponent("server.pid") }
    public var available: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: server.path) && fm.fileExists(atPath: text.path) && fm.fileExists(atPath: vision.path)
    }

    private func folder(_ name: String) throws -> URL {
        let target = root.appendingPathComponent(name)
        guard target.resolvingSymlinksInPath().path == target.standardizedFileURL.path else { throw MediaError.invalid("La carpeta del modelo no puede ser un enlace simbólico.") }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
    /// Downloads to a temporary file and returns it only when its size and SHA-256 match.
    private func fetch(_ asset: Asset, before: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let total = Self.downloadSize
        let (file, response) = try await ProgressDownload.run(URL(string: asset.url)!, expected: asset.size) { progress(.init(received: before + min($0.received, asset.size), total: total)) }
        do {
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("Descarga fallida: \(asset.name).") }
            try await Task.detached {
                let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
                var hash = SHA256(); var size: Int64 = 0
                while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data); size += Int64(data.count) }
                guard size == asset.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw MediaError.invalid("La descarga de \(asset.name) no supera la verificación SHA-256.") }
            }.value
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private func place(_ file: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: file) } else { try fm.moveItem(at: file, to: destination) }
    }
    /// Installs whatever is missing; files already in place are kept.
    public func install(progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws {
        guard Self.supported else { throw MediaError.invalid("El mapa mental necesita un Mac con Apple silicon.") }
        let fm = FileManager.default
        var done: Int64 = 0
        progress(.init(received: 0, total: Self.downloadSize))
        if !fm.isExecutableFile(atPath: server.path) {
            let runtime = try folder("runtime")
            let archive = try await fetch(Self.archive, before: done, progress: progress)
            defer { try? fm.removeItem(at: archive) }
            let stage = runtime.appendingPathComponent(".install-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.arguments = ["-xzf", archive.path, "-C", stage.path]
            tar.standardOutput = FileHandle.nullDevice; tar.standardError = FileHandle.nullDevice
            try await Task.detached { try tar.run(); tar.waitUntilExit() }.value
            let unpacked = stage.appendingPathComponent(Self.build)
            guard tar.terminationStatus == 0, fm.isExecutableFile(atPath: unpacked.appendingPathComponent("llama-server").path) else { throw MediaError.invalid("No se pudo preparar el motor local.") }
            try Task.checkCancellation()
            try place(unpacked, at: runtime.appendingPathComponent(Self.build))
        }
        done += Self.archive.size
        for (asset, destination) in [(Self.textModel, text), (Self.visionModel, vision)] {
            if !fm.fileExists(atPath: destination.path) {
                _ = try folder("models")
                let file = try await fetch(asset, before: done, progress: progress)
                defer { try? fm.removeItem(at: file) }
                try Task.checkCancellation()
                try place(file, at: destination)
            }
            done += asset.size
            progress(.init(received: done, total: Self.downloadSize))
        }
    }
    public func uninstall() throws {
        NotebookEmbeddingServer.terminate(self)
        for name in ["runtime", "models"] where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            try FileManager.default.removeItem(at: folder(name))
        }
    }
}

/// Keeps one llama.cpp server while vectors are being asked for, and stops it when they are not.
/// It listens on this Mac only, behind a key made for each launch.
public actor NotebookEmbeddingServer: NotebookEmbedder {
    private let runtime: NotebookEmbeddingRuntime
    private var process: Process?
    private var port = 0, key = "", vision = false
    private var idle: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)
    /// Longer text is cut: one section is enough to place it, and the server refuses what exceeds its context.
    static let textLimit = 6_000
    public init(runtime: NotebookEmbeddingRuntime) { self.runtime = runtime }

    /// Ends a server left by this or an earlier launch. Safe from any thread, including at quit.
    public nonisolated static func terminate(_ runtime: NotebookEmbeddingRuntime) {
        guard let text = try? String(contentsOf: runtime.pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        // The number may belong to another program by now: only our own server is ended.
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == runtime.server.resolvingSymlinksInPath().path { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: runtime.pidFile)
    }
    public func stop() {
        idle?.cancel(); idle = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? FileManager.default.removeItem(at: runtime.pidFile)
    }

    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MediaError.invalid("No se pudo reservar un puerto local.") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
        }
        guard bound else { throw MediaError.invalid("No se pudo reservar un puerto local.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    /// The picture encoders double the memory in use, so they are loaded only when a picture is embedded.
    private func ensure(vision needed: Bool) async throws {
        idle?.cancel(); idle = nil
        if let process, process.isRunning, vision || !needed { return }
        guard runtime.available else { throw MediaError.invalid("El modelo del mapa mental no está instalado.") }
        stop(); Self.terminate(runtime)
        port = try Self.freePort(); key = UUID().uuidString; vision = needed
        FileManager.default.createFile(atPath: runtime.log.path, contents: nil)
        let log = try FileHandle(forWritingTo: runtime.log)
        let launched = Process()
        launched.executableURL = runtime.server
        launched.arguments = ["-m", runtime.text.path, "--embedding", "--host", "127.0.0.1", "--port", String(port), "--api-key", key, "--no-webui",
                              "-np", "1", "-c", "4096", "-b", "4096", "-ub", "4096"] + (needed ? ["--mmproj", runtime.vision.path, "--image-max-tokens", "280"] : [])
        launched.currentDirectoryURL = runtime.root
        launched.standardInput = FileHandle.nullDevice; launched.standardOutput = log; launched.standardError = log
        launched.qualityOfService = .utility
        try launched.run()
        try? log.close()
        process = launched
        try? Data(String(launched.processIdentifier).utf8).write(to: runtime.pidFile, options: .atomic)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!); request.timeoutInterval = 2
        for _ in 0..<240 {
            guard launched.isRunning else { break }
            if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { stop(); throw error }
        }
        stop()
        throw MediaError.invalid("El motor local del mapa mental no arrancó. Detalle en \(runtime.log.path).")
    }
    private func rest() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            if !Task.isCancelled { await self?.stop() }
        }
    }
    private func request(_ inputs: [Any]) async throws -> [[Float]] {
        struct Response: Decodable { struct Row: Decodable { let embedding: [Float]; let index: Int }; let data: [Row] }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/embeddings")!)
        request.httpMethod = "POST"; request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": inputs])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("El motor local rechazó el contenido: " + String(decoding: data.prefix(300), as: UTF8.self)) }
        let rows = try JSONDecoder().decode(Response.self, from: data).data.sorted { $0.index < $1.index }
        guard rows.count == inputs.count else { throw MediaError.invalid("El motor local devolvió una respuesta incompleta.") }
        return try rows.map { try Self.shorten($0.embedding) }
    }
    /// The leading part of a Matryoshka vector, scaled back to length one.
    static func shorten(_ vector: [Float]) throws -> [Float] {
        guard vector.count >= NotebookEmbeddingRuntime.dimensions else { throw MediaError.invalid("El motor local devolvió un vector inesperado.") }
        let head = Array(vector.prefix(NotebookEmbeddingRuntime.dimensions))
        let length = head.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard length.isFinite, length > 0 else { throw MediaError.invalid("El motor local devolvió un vector vacío.") }
        return head.map { $0 / length }
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await ensure(vision: false)
        defer { rest() }
        let cut = texts.map { String($0.prefix(Self.textLimit)) }
        do { return try await request(cut) } catch is CancellationError { throw CancellationError() } catch {
            // Dense text (formulas, code) can exceed the context where prose does not: each one is retried, shorter.
            var result: [[Float]] = []
            for text in cut {
                try Task.checkCancellation()
                var piece = text, vector: [Float]?
                while vector == nil {
                    do { vector = try await request([piece]).first } catch {
                        guard piece.count > 400, process?.isRunning == true else { throw error }
                        piece = String(piece.prefix(piece.count / 2))
                    }
                }
                result.append(vector!)
            }
            return result
        }
    }
    public func embed(image: Data) async throws -> [Float] {
        try await ensure(vision: true)
        defer { rest() }
        let part: [String: Any] = ["type": "image_url", "image_url": ["url": "data:image/png;base64," + image.base64EncodedString()]]
        guard let vector = try await request([["content": [part]]]).first else { throw MediaError.invalid("El motor local devolvió una respuesta incompleta.") }
        return vector
    }
}
