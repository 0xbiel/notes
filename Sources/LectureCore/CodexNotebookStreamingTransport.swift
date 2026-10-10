import Foundation

struct CodexNotebookStreamingTransport {
    let store: LocalMediaStore
    let configuration: AIProviderConfiguration

    func generate(_ prompt: String, language: String, images: [NotebookInputImage], webEnabled: Bool = true, progress: @escaping @Sendable (NotebookProviderProgress) async -> Void) async throws -> String {
        let directory = try NotesProviderTransport(store: store).temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Retain the configured account, but exclude its config, rules, plugins,
        // hooks and skills from this ephemeral text-only helper.
        let accountHome = configuration.homePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") : URL(fileURLWithPath: configuration.homePath)
        let auth = accountHome.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: auth.path) {
            let target = home.appendingPathComponent("auth.json")
            try FileManager.default.copyItem(at: auth, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        var environment = ProcessInfo.processInfo.environment
        for name in environment.keys where name.hasPrefix("CODEX_") || name.hasPrefix("T3CODE_") { environment.removeValue(forKey: name) }
        environment["CODEX_HOME"] = home.path
        let instructions = NotebookAssistantProtocol.instructions(language: language) + "\n" + NotebookAssistantProtocol.webInstructions(enabled: webEnabled, native: true)
        let exec = NotesProviderTransport.codexArguments(configuration, schema: directory.appendingPathComponent("unused-schema"), instructions: instructions, allowWebSearch: webEnabled)
        var arguments = ["app-server", "--listen", "stdio://", "--config", "sandbox_mode=\"read-only\"", "--config", "cli_auth_credentials_store=\"file\""]
        for index in exec.indices where ["--config", "--disable"].contains(exec[index]) && index + 1 < exec.count { arguments += [exec[index], exec[index + 1]] }
        let connection = ProviderRPCConnection(configuration: configuration, directory: directory, environment: environment, arguments: arguments)
        let events = AsyncStream<NotebookProviderProgress>.makeStream()
        return try await withTaskCancellationHandler {
            let worker = Task.detached {
                defer { connection.close(); events.continuation.finish() }
                try connection.start()
                _ = try connection.request("initialize", params: ["clientInfo": ["name": "palladium", "title": "Palladium", "version": "0.3"], "capabilities": ["experimentalApi": true]])
                try connection.notify("initialized")
                var threadParams: [String: Any] = ["ephemeral": true, "cwd": directory.path, "approvalPolicy": "never", "sandbox": "read-only", "developerInstructions": instructions]
                if configuration.model != "default" { threadParams["model"] = configuration.model }
                let result = try connection.request("thread/start", params: threadParams)
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw MediaError.invalid("Codex no inició el hilo.") }
                var decoder = CodexNotebookProgressDecoder(threadID: id, webEnabled: webEnabled)
                connection.notificationHandler = { method, params in
                    if let update = try decoder.accept(method, params) { events.continuation.yield(update) }
                }
                var input: [[String: Any]] = [["type": "text", "text": prompt]]
                for (index, image) in images.enumerated() {
                    let path = directory.appendingPathComponent("attachment-\(index).png")
                    try image.data.write(to: path)
                    input.append(["type": "localImage", "path": path.path])
                }
                var turn: [String: Any] = ["threadId": id, "input": input, "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly", "networkAccess": false], "summary": "detailed", "outputSchema": NotebookAssistantProtocol.schema]
                if let effort = configuration.reasoningEffort { turn["effort"] = effort }
                _ = try connection.request("turn/start", params: turn)
                while !decoder.finished {
                    let event = try connection.readEvent()
                    if event["id"] != nil { throw MediaError.invalid("Codex solicitó herramientas o permisos; respuesta rechazada.") }
                    if let method = event["method"] as? String { _ = try decoder.accept(method, event["params"] as? [String: Any] ?? [:]).map { events.continuation.yield($0) } }
                }
                guard !decoder.output.isEmpty else { throw MediaError.invalid("Codex no devolvió una respuesta completa.") }
                return decoder.output
            }
            for await event in events.stream { await progress(event) }
            return try await worker.value
        } onCancel: { connection.cancel() }
    }
}

struct CodexNotebookProgressDecoder {
    let threadID: String
    var webEnabled = false
    private var turnID: String?
    private var parts: [String: [Int: String]] = [:]
    private(set) var output = ""
    private(set) var finished = false
    mutating func accept(_ method: String, _ params: [String: Any]) throws -> NotebookProviderProgress? {
        guard params["threadId"] as? String == threadID else { return nil }
        if let id = params["turnId"] as? String, let turnID, id != turnID { return nil }
        if method == "turn/started", let turn = params["turn"] as? [String: Any] {
            turnID = turn["id"] as? String
            return .init(id: "provider-start", title: "Pensando…", kind: .reasoning)
        }
        if method == "item/reasoning/summaryTextDelta" || method == "item/reasoning/textDelta",
           let id = params["itemId"] as? String, let delta = params["delta"] as? String {
            let summary = method.contains("summaryText")
            let key = id + (summary ? "-summary" : "-content")
            let index = params[summary ? "summaryIndex" : "contentIndex"] as? Int ?? 0
            parts[key, default: [:]][index] = String(((parts[key]?[index] ?? "") + delta).prefix(12_000))
            let detail = parts[key]!.keys.sorted().compactMap { parts[key]?[$0] }.joined(separator: "\n\n")
            return .init(id: "thought-" + key, title: "Pensando…", detail: detail, kind: .reasoning)
        }
        if method == "item/agentMessage/delta" { return .init(id: "provider-response", title: "Redactando respuesta…") }
        if ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any], let kind = item["type"] as? String {
            if kind == "webSearch", webEnabled {
                let action = item["action"] as? [String: Any]
                return .init(id: "web-" + (item["id"] as? String ?? "current"), title: "Buscando en la web…", detail: action?["query"] as? String, kind: .tool)
            }
            guard ["reasoning", "agentMessage", "userMessage"].contains(kind) else { throw MediaError.invalid("Codex devolvió un evento no permitido; respuesta rechazada.") }
            if method == "item/completed", kind == "agentMessage", let text = item["text"] as? String { output = String(text.prefix(60_000)) }
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            guard turn["status"] as? String == "completed" else { throw MediaError.invalid("Codex no completó el lote; revisa la cuenta/configuración y reintenta explícitamente.") }
            finished = true
            return .init(id: "provider-finished", title: "Comprobando respuesta…")
        }
        return nil
    }
}
