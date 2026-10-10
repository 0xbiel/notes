import Foundation
import Security

public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable {
    case local, openAI
    public var title: String { self == .local ? "Whisper · Local" : "OpenAI · API" }
}

/// Credentials never enter job manifests, preferences files or request logs.
public enum TranscriptionKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Palladium.Transcription", kSecAttrAccount as String: "OpenAI"] }
    public static func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else { throw MediaError.invalid("No se pudo acceder al llavero de transcripción.") }
        return key
    }
    public static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MediaError.invalid("No se pudo eliminar la clave del llavero.") }; return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MediaError.invalid("No se pudo guardar la clave en el llavero.") }
    }
}

public struct APIAudioTranscriber: Sendable {
    private let readKey: @Sendable () throws -> String?
    private let upload: @Sendable (URLRequest, Data) async throws -> (Data, URLResponse)
    public init() {
        self.init(readKey: { try TranscriptionKeychain.read() }, upload: { request, body in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            return try await session.upload(for: request, from: body)
        })
    }
    init(readKey: @escaping @Sendable () throws -> String?, upload: @escaping @Sendable (URLRequest, Data) async throws -> (Data, URLResponse)) {
        self.readKey = readKey; self.upload = upload
    }
    public func transcribe(audio: URL, offset: Double, duration: Double, chunk: Int, language: String) async throws -> [MediaTranscriptSegment] {
        guard let key = try readKey(), !key.isEmpty else { throw MediaError.invalid("Añade una clave OpenAI en Preferencias → Transcripción.") }
        let boundary = "Palladium-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
        field("model", "whisper-1"); field("response_format", "verbose_json"); field("timestamp_granularities[]", "segment")
        if language != "auto" { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        let data = try Data(contentsOf: audio)
        guard data.count < 25_000_000 else { throw MediaError.invalid("Fragmento demasiado grande para la API.") }
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (response, metadata) = try await upload(request, body)
        try Task.checkCancellation()
        guard let http = metadata as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (metadata as? HTTPURLResponse)?.statusCode ?? 0
            throw MediaError.invalid(code == 401 ? "Clave OpenAI no válida. Revísala en Preferencias." : code == 429 ? "Límite o saldo de OpenAI agotado. Puedes reanudar más tarde." : "La transcripción API falló (HTTP \(code)). El audio sigue guardado; puedes reanudar.")
        }
        return try Self.decode(response, offset: offset, duration: duration, chunk: chunk)
    }
    public static func decode(_ data: Data, offset: Double, duration: Double, chunk: Int) throws -> [MediaTranscriptSegment] {
        struct Response: Decodable { struct Segment: Decodable { let start: Double; let end: Double; let text: String }; let segments: [Segment] }
        return try JSONDecoder().decode(Response.self, from: data).segments.enumerated().compactMap { index, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start, segment.end <= duration + 0.5 else { return nil }
            return MediaTranscriptSegment(id: "\(chunk)-\(index)", start: offset + segment.start, end: offset + min(duration, segment.end), text: text)
        }
    }
}
