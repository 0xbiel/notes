import Foundation

struct CodexNotebookStreamingTransport {
    let store: LocalMediaStore
    let configuration: AIProviderConfiguration

    /// Retains the configured account, but excludes its config, rules, plugins,
    /// hooks and skills from an ephemeral helper.
    static func accountHome(_ configuration: AIProviderConfiguration, in directory: URL) throws -> URL {
        let home = directory.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let accountHome = configuration.accountHomePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") : URL(fileURLWithPath: configuration.accountHomePath)
        let auth = accountHome.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: auth.path) {
            let target = home.appendingPathComponent("auth.json")
            try Data(contentsOf: auth).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        try CodexConnectionConfiguration.copy(configuration, to: home)
        return home
    }

    func generate(_ prompt: String, language: String, images: [NotebookInputImage], webEnabled: Bool = true, usage: @escaping @Sendable (ProviderTokenUsage) -> Void = { _ in }, progress: @escaping @Sendable (NotebookProviderProgress) async -> Void, session: NotebookNativeSession? = nil, compact: Bool = false) async throws -> String {
        let directory = try session?.directory ?? NotesProviderTransport(store: store).temporaryDirectory()
        defer { if session == nil { try? FileManager.default.removeItem(at: directory) } }
        let home = try Self.accountHome(configuration, in: directory)
        let environment = try NotesProviderTransport.codexEnvironment(configuration, home: home.path)
        let instructions = NotebookAssistantProtocol.instructions(language: language) + "\n" + NotebookAssistantProtocol.outputInstructions + "\n" + NotebookAssistantProtocol.webInstructions(enabled: webEnabled, native: true)
        let exec = try NotesProviderTransport.codexArguments(configuration, schema: directory.appendingPathComponent("unused-schema"), instructions: instructions, allowWebSearch: webEnabled)
        var arguments = ["app-server", "--listen", "stdio://", "--config", "sandbox_mode=\"read-only\"", "--config", "cli_auth_credentials_store=\"file\""]
        for index in exec.indices where ["--config", "--enable", "--disable"].contains(exec[index]) && index + 1 < exec.count { arguments += [exec[index], exec[index + 1]] }
        let connection = ProviderRPCConnection(configuration: configuration, directory: directory, environment: environment, arguments: arguments, removeDirectoryOnClose: session == nil)
        let events = AsyncStream<NotebookProviderProgress>.makeStream()
        return try await withTaskCancellationHandler {
            let worker = Task.detached {
                defer { connection.close(); events.continuation.finish() }
                try connection.start()
                _ = try connection.request("initialize", params: ["clientInfo": ["name": "palladium", "title": "Palladium", "version": "0.3"], "capabilities": ["experimentalApi": true]])
                try connection.notify("initialized")
                var threadParams: [String: Any] = ["cwd": directory.path, "approvalPolicy": "never", "sandbox": "read-only", "developerInstructions": instructions]
                if configuration.model != "default" { threadParams["model"] = configuration.model }
                let savedID = try session?.load().nativeID
                if let savedID { threadParams["threadId"] = savedID; threadParams["excludeTurns"] = true }
                else { threadParams["ephemeral"] = session == nil }
                let result = try connection.request(savedID == nil ? "thread/start" : "thread/resume", params: threadParams)
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw MediaError.invalid("Codex no inició el hilo.") }
                guard savedID == nil || savedID == id else { throw MediaError.invalid("Codex resumed a different session; response rejected.") }
                try session?.started(id)
                var decoder = CodexNotebookProgressDecoder(threadID: id, webEnabled: webEnabled, model: result["model"] as? String ?? configuration.model, compact: compact, initialUsage: try session?.load().cumulativeUsage)
                defer { if let total = decoder.usage { usage(total) } }
                connection.notificationHandler = { method, params in
                    if let update = try decoder.accept(method, params) {
                        if let context = update.context { try session?.update(context) }
                        if let cumulative = decoder.cumulativeUsage, var record = try session?.load() {
                            record.cumulativeUsage = cumulative; try session?.save(record)
                        }
                        events.continuation.yield(update)
                    }
                }
                var input: [[String: Any]] = [["type": "text", "text": prompt]]
                for (index, image) in images.enumerated() {
                    let path = directory.appendingPathComponent("attachment-\(UUID().uuidString)-\(index).png")
                    try image.data.write(to: path)
                    input.append(["type": "localImage", "path": path.path])
                }
                var turn: [String: Any] = ["threadId": id, "input": input, "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly", "networkAccess": false], "summary": "detailed", "outputSchema": NotebookAssistantProtocol.schema]
                if let effort = configuration.reasoningEffort { turn["effort"] = effort }
                _ = try connection.request(compact ? "thread/compact/start" : "turn/start", params: compact ? ["threadId": id] : turn)
                while !decoder.finished {
                    let event = try connection.readEvent()
                    if event["id"] != nil { throw MediaError.invalid("Codex solicitó herramientas o permisos; respuesta rechazada.") }
                    if let method = event["method"] as? String, let update = try decoder.accept(method, event["params"] as? [String: Any] ?? [:]) {
                        if let context = update.context { try session?.update(context) }
                        if let cumulative = decoder.cumulativeUsage, var record = try session?.load() {
                            record.cumulativeUsage = cumulative; try session?.save(record)
                        }
                        events.continuation.yield(update)
                    }
                }
                if compact {
                    guard decoder.didCompact else { throw MediaError.invalid("Codex did not confirm native compaction.") }
                    var record = try session?.load(); record?.compactedAt = Date()
                    if !decoder.reportedPostCompactContext { record?.context = nil }
                    if let record { try session?.save(record) }
                    return ""
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
    var model = "default"
    var compact = false
    var initialUsage: ProviderTokenUsage?
    private(set) var cumulativeUsage: ProviderTokenUsage?
    private(set) var didCompact = false
    private(set) var reportedPostCompactContext = false
    /// Thread total so far; Codex counts cached tokens inside the input.
    private(set) var usage: ProviderTokenUsage?
    private var turnID: String?
    private var parts: [String: [Int: String]] = [:]
    private(set) var output = ""
    private(set) var finished = false
    private var response = NotebookResponseStream()
    private var writing = false

    init(threadID: String, webEnabled: Bool = false, model: String = "default", compact: Bool = false, initialUsage: ProviderTokenUsage? = nil) {
        self.threadID = threadID
        self.webEnabled = webEnabled
        self.model = model
        self.compact = compact
        self.initialUsage = initialUsage
    }

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
            let detail = String(((parts[key]?[index] ?? "") + delta).prefix(12_000))
            parts[key, default: [:]][index] = detail
            // Each summary section is a titled thought of its own.
            return .init(id: "thought-" + key + (index == 0 ? "" : "-\(index)"), title: "Pensando…", detail: detail, kind: .reasoning)
        }
        if method == "thread/tokenUsage/updated", let tokens = params["tokenUsage"] as? [String: Any], let total = tokens["last"] as? [String: Any] ?? tokens["total"] as? [String: Any] {
            let count = ProviderTokenUsage.count
            let billed = tokens["total"] as? [String: Any] ?? total
            let cached = count(billed["cachedInputTokens"])
            let cumulative = ProviderTokenUsage(model: model, input: count(billed["inputTokens"]) - cached, cachedInput: cached, output: count(billed["outputTokens"]))
            cumulativeUsage = cumulative
            usage = .init(model: model, input: cumulative.input - (initialUsage?.input ?? 0), cachedInput: cumulative.cachedInput - (initialUsage?.cachedInput ?? 0), output: cumulative.output - (initialUsage?.output ?? 0))
            reportedPostCompactContext = didCompact
            let context = NotebookNativeContext(usedTokens: count(total["totalTokens"] ?? (count(total["inputTokens"]) + count(total["outputTokens"]))), maxTokens: tokens["modelContextWindow"] as? Int, model: model, compacted: didCompact)
            return .init(id: "native-context", title: "", context: context)
        }
        if method == "thread/compacted" { didCompact = true; return .init(id: "native-compact", title: "Contexto compactado") }
        if method == "item/agentMessage/delta" {
            let update = (params["delta"] as? String).flatMap { response.accept($0) }
            defer { writing = true }
            return update ?? (writing ? nil : .init(id: "provider-response", title: "Redactando respuesta…"))
        }
        if ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any], let kind = item["type"] as? String {
            if kind == "contextCompaction" {
                if method == "item/completed" { didCompact = true }
                return .init(id: "native-compact", title: didCompact ? "Contexto compactado" : "Compactando contexto…")
            }
            if kind == "webSearch", webEnabled {
                let action = item["action"] as? [String: Any]
                return .init(id: "web-" + (item["id"] as? String ?? "current"), title: "Buscando en la web…", detail: action?["query"] as? String, kind: .tool)
            }
            guard ["reasoning", "agentMessage", "userMessage"].contains(kind) else { throw MediaError.invalid("Codex devolvió un evento no permitido; respuesta rechazada.") }
            if method == "item/completed", kind == "agentMessage", let text = item["text"] as? String { output = text }
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            guard turn["status"] as? String == "completed" else { throw MediaError.invalid("Codex no completó el lote; revisa la cuenta/configuración y reintenta explícitamente.") }
            finished = true
            return .init(id: "provider-finished", title: "Comprobando respuesta…")
        }
        return nil
    }
}
