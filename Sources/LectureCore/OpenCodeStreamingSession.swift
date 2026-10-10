import Foundation

/// `opencode run --format json` waits for reasoning to end. Subscribe to the
/// managed server's native SSE deltas instead; the final HTTP reply still goes
/// through the existing complete-response and zero-cost validation.
struct OpenCodeStreamingSession {
    let harness: OpenRouterHarness

    func generate(_ prompt: String, progress: @escaping @Sendable (NotebookProviderProgress) async -> Void) async throws -> Data {
        let context = try harness.environment(syntheticDemo: false)
        let server = NotesProcess(timeoutInterval: ProviderRequestLimits.generation)
        let password = UUID().uuidString
        server.process.executableURL = URL(fileURLWithPath: harness.executablePath)
        server.process.arguments = ["--pure", "serve", "--hostname", "127.0.0.1", "--port", "0"]
        server.process.currentDirectoryURL = context.directory
        var environment = context.variables
        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        server.process.environment = environment
        server.process.standardInput = FileHandle.nullDevice
        let ready = AsyncThrowingStream<URL, Error>.makeStream()
        let worker = Task.detached {
            do {
                _ = try server.run { line in
                    let text = String(decoding: line, as: UTF8.self)
                    guard let range = text.range(of: "http://127.0.0.1:"),
                          let url = URL(string: String(text[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)),
                          url.host == "127.0.0.1", url.port != nil else { return }
                    ready.continuation.yield(url); ready.continuation.finish()
                }
                ready.continuation.finish(throwing: MediaError.invalid("OpenCode cerró el servidor antes de conectar."))
            } catch { ready.continuation.finish(throwing: error) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ProviderRequestLimits.generation
        configuration.timeoutIntervalForResource = ProviderRequestLimits.generation
        configuration.connectionProxyDictionary = [:]
        let http = URLSession(configuration: configuration)
        defer { server.cancel(); worker.cancel(); http.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            var iterator = ready.stream.makeAsyncIterator()
            guard let base = try await iterator.next() else { throw MediaError.invalid("OpenCode no inició el servidor.") }
            let authorization = "Basic " + Data(("opencode:" + password).utf8).base64EncodedString()
            func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
                var request = URLRequest(url: base.appendingPathComponent(path))
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                if let body {
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                }
                return request
            }
            func data(_ request: URLRequest) async throws -> Data {
                let (data, response) = try await http.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 2_000_000 else {
                    throw MediaError.invalid("OpenCode no completó la petición local. No se ha cambiado la nota.")
                }
                return data
            }
            try OpenRouterHarness.verifyConfig(try await data(request("config")), notebookEditing: true, allowRetention: harness.allowRetention)
            let created = try JSONSerialization.jsonObject(with: await data(request("session", body: ["title": "Notebook edit"]))) as? [String: Any]
            guard let id = created?["id"] as? String, !id.isEmpty, !id.contains("/") else { throw MediaError.invalid("Sesión OpenCode inválida.") }
            let (bytes, response) = try await http.bytes(for: request("event"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("OpenCode no abrió el flujo de eventos.") }
            let reader = Task {
                var decoder = OpenCodeProgressDecoder(sessionID: id)
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data: "), line.utf8.count <= 2_000_000 else { continue }
                    if let update = decoder.accept(Data(line.dropFirst(6).utf8)) { await progress(update) }
                    if decoder.finished { return }
                }
                throw MediaError.invalid("Se interrumpió el flujo de OpenCode. Reintenta explícitamente.")
            }
            defer { reader.cancel() }
            let reply = try await data(request("session/" + id + "/message", body: [
                "agent": OpenRouterHarness.agent,
                "model": ["providerID": "openrouter", "modelID": "openrouter/free"],
                "system": NotebookAssistantProtocol.instructions,
                "parts": [["type": "text", "text": prompt + "\nReturn only the protocol JSON object with reply, readFiles and edits. Put the answer inside reply; never return it as plain text."]]
            ]))
            try await reader.value
            try Task.checkCancellation()
            return try Self.completeEvents(reply)
        } onCancel: { server.cancel(); http.invalidateAndCancel() }
    }

    static func completeEvents(_ data: Data) throws -> Data {
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = reply["info"] as? [String: Any], let parts = reply["parts"] as? [[String: Any]] else { throw MediaError.invalid("Respuesta OpenCode inválida.") }
        if let error = info["error"] as? [String: Any] {
            let event = try JSONSerialization.data(withJSONObject: ["type": "error", "error": error])
            throw MediaError.invalid(OpenRouterHarness.providerFailure(event) ?? "OpenCode no pudo completar la petición. No se ha cambiado la nota.")
        }
        guard let cost = info["cost"] as? Double, cost.isFinite, cost == 0, info["role"] as? String == "assistant" else { throw MediaError.invalid("No hay respuesta completa con coste cero; no se ha cambiado la nota.") }
        var events = Data()
        for part in parts {
            let kind = part["type"] as? String
            let type = kind == "tool" ? "tool_use" : kind == "step-finish" ? "step_finish" : kind ?? ""
            events.append(try JSONSerialization.data(withJSONObject: ["type": type, "part": part])); events.append(10)
        }
        return events
    }
}

/// Snapshots replace accumulated text; deltas append only to a known reasoning
/// part in this session. Text/JSON response chunks are never shown as thoughts.
struct OpenCodeProgressDecoder {
    let sessionID: String
    private var thoughts: [String: String] = [:]
    private var began = false
    private(set) var finished = false
    mutating func accept(_ data: Data) -> NotebookProviderProgress? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String, let properties = event["properties"] as? [String: Any] else { return nil }
        if type == "message.part.updated", let part = properties["part"] as? [String: Any], part["sessionID"] as? String == sessionID {
            began = true
            let kind = part["type"] as? String
            if kind == "reasoning", let id = part["id"] as? String {
                let text = String((part["text"] as? String ?? "").prefix(12_000))
                thoughts[id] = text
                return .init(id: "thought-" + id, title: "Pensando…", detail: text, kind: .reasoning)
            }
            let mapped = kind == "step-start" ? "step_start" : kind == "step-finish" ? "step_finish" : kind == "tool" ? "tool_use" : kind ?? ""
            if let line = try? JSONSerialization.data(withJSONObject: ["type": mapped, "part": part]) { return NotebookProviderProgress.decode(line) }
        }
        guard properties["sessionID"] as? String == sessionID else { return nil }
        if type == "message.part.delta", properties["field"] as? String == "text", let id = properties["partID"] as? String,
           let delta = properties["delta"] as? String, let previous = thoughts[id] {
            let text = String((previous + delta).prefix(12_000)); thoughts[id] = text
            return .init(id: "thought-" + id, title: "Pensando…", detail: text, kind: .reasoning)
        }
        if type == "session.status", let status = properties["status"] as? [String: Any], status["type"] as? String == "idle", began { finished = true }
        if type == "session.error" { finished = true }
        return nil
    }
}
