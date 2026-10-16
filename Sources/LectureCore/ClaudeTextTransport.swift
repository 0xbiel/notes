import Foundation

/// Claude Code through `claude -p` with structured output, adapted from T3
/// Code's ClaudeTextGeneration. Each request runs in a private empty directory
/// with customizations, hooks, MCP servers, skills and file/command tools
/// disabled; the configured account and model selection remain in effect.
public struct ClaudeTextTransport: Sendable {
    let store: LocalMediaStore
    let configuration: AIProviderConfiguration
    var secret: ProviderEnvironment.SecretReader = { try ProviderSecrets.read($0, $1) }

    static let requiredFlags = ["--json-schema", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--tools", "--permission-mode"]
    /// Variables describing a parent Claude Code session; inheriting them would
    /// attach the helper to that session instead of starting a clean one.
    static let sessionVariables: Set<String> = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_PID", "CLAUDE_EFFORT"]

    func environment() throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for name in Array(environment.keys) where Self.sessionVariables.contains(name) || name.hasPrefix("T3CODE_") { environment.removeValue(forKey: name) }
        try ProviderEnvironment.apply(configuration, to: &environment, secret: secret)
        // CLAUDE_CONFIG_DIR, not HOME: the login Keychain lookup depends on HOME.
        if !configuration.homePath.isEmpty { environment["CLAUDE_CONFIG_DIR"] = configuration.homePath }
        return environment
    }

    /// Launch arguments come first so the isolation options below prevail.
    public static func arguments(_ configuration: AIProviderConfiguration, schema: [String: Any], instructions: String, webSearch: Bool = false, imageInput: Bool = false, sessionID: String? = nil, resume: Bool = false, compact: Bool = false) throws -> [String] {
        var settings: [String: Any] = ["disableAllHooks": true]
        if configuration.fastMode == true { settings["fastMode"] = true }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        var arguments = ["-p"] + (try ProviderLaunchArguments.resolve(configuration))
        arguments += ["--safe-mode", "--output-format", "stream-json", "--verbose"]
        // Thinking is omitted from the stream unless its summaries are requested,
        // as T3 Code does; a launch argument that sets it is left alone.
        if !arguments.contains(where: { $0.hasPrefix("--thinking") || $0 == "--max-thinking-tokens" }) {
            settings["showThinkingSummaries"] = true
            arguments += ["--thinking", "adaptive", "--thinking-display", "summarized", "--include-partial-messages"]
        }
        if imageInput || compact { arguments += ["--input-format", "stream-json"] }
        if !compact { arguments += ["--json-schema", try json(schema)] }
        arguments += ["--system-prompt", instructions, "--settings", try json(settings)]
        arguments += webSearch ? ["--tools", "WebSearch", "--allowedTools", "WebSearch"] : ["--tools", ""]
        arguments += ["--strict-mcp-config", "--permission-mode", "dontAsk"]
        // This flag also disables built-in /compact. Safe mode still excludes custom skills.
        if !compact { arguments += ["--disable-slash-commands"] }
        if let sessionID {
            guard UUID(uuidString: sessionID) != nil else { throw MediaError.invalid("Invalid Claude session identifier.") }
            arguments += [resume ? "--resume" : "--session-id", sessionID]
        } else { arguments += ["--no-session-persistence"] }
        let selection = ClaudeModel.selection(configuration)
        if let model = selection.model { arguments += ["--model", model] }
        if let effort = selection.effort { arguments += ["--effort", effort] }
        if let window = configuration.autoCompactWindow, !window.isEmpty { arguments += ["--autocompact", window] }
        return arguments
    }

    private func command(_ arguments: [String], directory: URL, timeout: TimeInterval) throws -> NotesProcess {
        let command = NotesProcess(timeoutInterval: timeout)
        command.process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        command.process.arguments = arguments
        command.process.currentDirectoryURL = directory
        command.process.environment = try environment()
        command.process.standardInput = FileHandle.nullDevice
        return command
    }

    private func output(_ arguments: [String]) async throws -> String {
        let command = try command(arguments, directory: store.root, timeout: ProviderRequestLimits.diagnostic)
        return try await withTaskCancellationHandler {
            String(decoding: try await Task.detached { try command.run() }.value, as: UTF8.self)
        } onCancel: { command.cancel() }
    }

    func installedVersion() async throws -> String {
        try configuration.validate()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else { throw MediaError.invalid("No se encuentra el ejecutable. Selecciona una instalación existente; Palladium no instala proveedores.") }
        guard let version = ClaudeModel.version(from: try await output(["--version"])) else { throw MediaError.invalid("El ejecutable no identifica una instalación de Claude Code.") }
        return version
    }

    public func diagnose() async throws -> AIProviderDiagnostic {
        let version = try await installedVersion()
        let help = try await output(["--help"])
        guard Self.requiredFlags.allSatisfy(help.contains) else { throw MediaError.invalid("Claude Code no ofrece el transporte aislado requerido. Actualiza su instalación fuera de Palladium.") }
        return .init(message: "Claude Code \(version) · salida estructurada disponible · no comprueba login ni envía texto", version: version)
    }

    public func models() async throws -> [AIProviderModel] {
        let models = ClaudeModel.catalog(version: try await installedVersion())
        guard !models.isEmpty else { throw MediaError.invalid("Esta versión de Claude Code es demasiado antigua. Actualiza su instalación fuera de Palladium.") }
        return models
    }

    public func send(_ batch: AIBatch, checked: @escaping @Sendable () async -> Void = {}) async throws -> AIBatch {
        let text = try await generate(String(decoding: try OpenRouterHarness.payload(batch), as: UTF8.self), schema: NotesProviderTransport.responseSchema, instructions: OpenRouterHarness.systemPrompt, checked: checked)
        var result = batch
        result.decisions = try OpenRouterHarness.decodeResponse(text, for: batch)
        result.stage = .ready; result.error = nil; result.reportedCost = nil
        return result
    }

    /// Returns the model's structured output as JSON text.
    func generate(_ prompt: String, schema: [String: Any], instructions: String, images: [NotebookInputImage] = [], webSearch: Bool = false, checked: @escaping @Sendable () async -> Void = {}, usage: @escaping @Sendable (ProviderTokenUsage) -> Void = { _ in }, progress: @escaping @Sendable (NotebookProviderProgress) async -> Void = { _ in }, session: NotebookNativeSession? = nil, compact: Bool = false) async throws -> String {
        try configuration.validateSending()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else { throw MediaError.invalid("No se encuentra el ejecutable. Selecciona una instalación existente; Palladium no instala proveedores.") }
        let directory = try session?.directory ?? NotesProviderTransport(store: store).temporaryDirectory()
        defer { if session == nil { try? FileManager.default.removeItem(at: directory) } }
        var record = try session?.load()
        if session != nil, record?.nativeID == nil { record?.nativeID = UUID().uuidString; if let record { try session?.save(record) } }
        let nativeID = record?.nativeID
        let input = directory.appendingPathComponent(session == nil ? "input.txt" : "input-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: input) }
        let inputData = compact
            ? try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": "/compact"]]) + Data([10])
            : try Self.input(prompt, images: images)
        try inputData.write(to: input, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let command = try command(try Self.arguments(configuration, schema: schema, instructions: instructions, webSearch: webSearch, imageInput: !images.isEmpty, sessionID: nativeID, resume: record?.initialized == true, compact: compact), directory: directory, timeout: ProviderRequestLimits.generation)
        // The stream repeats the reply in its tool call, tool result and result.
        command.outputLimit = nil
        let reader = try FileHandle(forReadingFrom: input)
        command.process.standardInput = reader
        defer { try? reader.close() }
        await checked()
        let events = AsyncStream<NotebookProviderProgress>.makeStream()
        let state = ClaudeStreamState(webSearch: webSearch, compact: compact)
        let worker = Task.detached {
            defer { state.decoder.usage.forEach(usage); events.continuation.finish() }
            do {
                _ = try command.run { line in
                    // The first rejected event stops the helper; later lines are ignored.
                    guard state.failure == nil else { return }
                    do {
                        if let update = try state.decoder.accept(line) {
                            if let actualID = state.decoder.nativeID, let nativeID {
                                guard actualID == nativeID else { throw MediaError.invalid("Claude resumed a different session; response rejected.") }
                                if try session?.load().initialized == false { try session?.started(actualID) }
                            }
                            if let context = update.context { try session?.update(context) }
                            events.continuation.yield(update)
                        }
                    }
                    catch { state.failure = error; command.cancel() }
                }
            } catch {
                throw state.failure ?? error
            }
            if let failure = state.failure { throw failure }
            if compact {
                guard state.decoder.didCompact else { throw MediaError.invalid("Claude did not confirm native compaction.") }
                if var record = try session?.load() {
                    record.compactedAt = Date()
                    if state.decoder.context?.compacted != true { record.context = nil }
                    try session?.save(record)
                }
                return ""
            }
            guard let output = state.decoder.output else { throw MediaError.invalid("Claude no devolvió una respuesta completa.") }
            return output
        }
        return try await withTaskCancellationHandler {
            for await event in events.stream { await progress(event) }
            return try await worker.value
        } onCancel: { command.cancel() }
    }

    /// The account's limits, from the `get_usage` control request. No user
    /// message is written, so the helper answers without a model request.
    func usage() async throws -> [String: Any] {
        try configuration.validate()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else { throw MediaError.invalid("No se encuentra el ejecutable. Selecciona una instalación existente; Palladium no instala proveedores.") }
        let directory = try NotesProviderTransport(store: store).temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.txt")
        let requests = [["type": "control_request", "request_id": "initialize", "request": ["subtype": "initialize"]],
                        ["type": "control_request", "request_id": "usage", "request": ["subtype": "get_usage", "skip_behaviors": true]]]
        try Data(try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined().utf8).write(to: input, options: .withoutOverwriting)
        let command = try command(["-p", "--safe-mode", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--settings", "{\"disableAllHooks\":true}", "--tools", "",
                                   "--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk", "--no-session-persistence"], directory: directory, timeout: ProviderRequestLimits.diagnostic)
        let reader = try FileHandle(forReadingFrom: input)
        command.process.standardInput = reader
        defer { try? reader.close() }
        let output = try await withTaskCancellationHandler { try await Task.detached { try command.run() }.value } onCancel: { command.cancel() }
        for line in output.split(separator: 10) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], event["type"] as? String == "control_response",
                  let response = event["response"] as? [String: Any], response["request_id"] as? String == "usage" else { continue }
            guard response["subtype"] as? String == "success", let usage = response["response"] as? [String: Any] else { break }
            return usage
        }
        throw MediaError.invalid("Esta versión de Claude Code no informa de los límites de la cuenta.")
    }

    static func input(_ prompt: String, images: [NotebookInputImage]) throws -> Data {
        guard !images.isEmpty else { return Data(prompt.utf8) }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        content += images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.data.base64EncodedString()]] }
        var line = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": content]])
        line.append(10)
        return line
    }
}

private final class ClaudeStreamState: @unchecked Sendable {
    var decoder: ClaudeStreamDecoder
    var failure: Error?
    init(webSearch: Bool, compact: Bool = false) { decoder = ClaudeStreamDecoder(webSearch: webSearch, compact: compact) }
}

/// Reads `--output-format stream-json` lines. The session must expose only the
/// structured-output tool (plus web search when the request allows it); any
/// other tool, MCP server or failed result rejects the response.
struct ClaudeStreamDecoder {
    var webSearch = false
    var compact = false
    private(set) var nativeID: String?
    private(set) var didCompact = false
    private(set) var context: NotebookNativeContext?
    private(set) var output: String?
    /// Tokens per model, read from the final result even when it failed.
    private(set) var usage: [ProviderTokenUsage] = []
    private var model = ""
    private var thoughts = 0
    /// Thinking blocks being streamed, by content index, and those whose
    /// complete `assistant` copy has not arrived yet.
    private var streaming: [Int: (id: String, text: String, shown: Int)] = [:]
    private var streamed: [String] = []
    /// The structured-output tool call, whose input is the response being written.
    private var responseBlock: Int?
    private var response = NotebookResponseStream()
    private var streamedResponse = false

    private var allowedTools: Set<String> { webSearch ? ["StructuredOutput", "WebSearch"] : ["StructuredOutput"] }

    mutating func accept(_ line: Data) throws -> NotebookProviderProgress? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String else { return nil }
        switch type {
        case "system":
            if event["subtype"] as? String == "compact_boundary" {
                didCompact = true
                if let metadata = event["compact_metadata"] as? [String: Any], let tokens = metadata["post_tokens"] as? Int, tokens > 0 {
                    context = .init(usedTokens: tokens, maxTokens: context?.maxTokens, model: model, compacted: true)
                }
                return .init(id: "native-compact", title: "Contexto compactado", context: context?.compacted == true ? context : nil)
            }
            guard event["subtype"] as? String == "init" else { return nil }
            nativeID = event["session_id"] as? String
            let tools = event["tools"] as? [String] ?? []
            let servers = event["mcp_servers"] as? [Any] ?? []
            model = event["model"] as? String ?? ""
            guard Set(tools).isSubset(of: allowedTools), servers.isEmpty else { throw MediaError.invalid("La sesión de Claude conserva herramientas o servidores MCP; no se ha enviado contenido.") }
            return .init(id: "provider-start", title: "Pensando…", kind: .reasoning)
        case "assistant":
            guard let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return nil }
            if let usage = message["usage"] as? [String: Any] {
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0) { $0 + ProviderTokenUsage.count(usage[$1]) }
                context = .init(usedTokens: tokens, maxTokens: context?.maxTokens, model: message["model"] as? String ?? model)
            }
            var update: NotebookProviderProgress?
            for block in blocks {
                switch block["type"] as? String {
                case "thinking":
                    let id: String
                    if streamed.isEmpty { thoughts += 1; id = "thought-\(thoughts)" } else { id = streamed.removeFirst() }
                    let text = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    update = .init(id: id, title: "Pensando…", detail: text.isEmpty ? nil : text, kind: .reasoning)
                case "text": update = .init(id: "provider-response", title: "Redactando respuesta…")
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    guard allowedTools.contains(name) else { throw MediaError.invalid("Claude intentó usar una herramienta no permitida (\(name.prefix(60))); respuesta rechazada.") }
                    if name == "WebSearch" {
                        let query = (block["input"] as? [String: Any])?["query"] as? String
                        update = .init(id: "web-" + (block["id"] as? String ?? "current"), title: "Buscando en la web…", detail: query, kind: .tool)
                    } else if !streamedResponse { update = .init(id: "provider-response", title: "Redactando respuesta…") }
                default: continue
                }
            }
            return update
        case "stream_event":
            guard event["parent_tool_use_id"] as? String == nil, let inner = event["event"] as? [String: Any], let index = inner["index"] as? Int else { return nil }
            switch inner["type"] as? String {
            case "content_block_start":
                guard let block = inner["content_block"] as? [String: Any] else { return nil }
                if block["type"] as? String == "tool_use", block["name"] as? String == "StructuredOutput" { responseBlock = index; response = .init(); streamedResponse = true }
                guard block["type"] as? String == "thinking" else { return nil }
                thoughts += 1
                streaming[index] = ("thought-\(thoughts)", block["thinking"] as? String ?? "", 0)
                streamed.append("thought-\(thoughts)")
            case "content_block_delta":
                if index == responseBlock, let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta", let json = delta["partial_json"] as? String {
                    return response.accept(json)
                }
                guard let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "thinking_delta", let text = delta["thinking"] as? String, streaming[index] != nil else { return nil }
                streaming[index]!.text = String((streaming[index]!.text + text).prefix(12_000))
                // Tokens arrive one by one; the log is redrawn every few words instead.
                guard streaming[index]!.text.count - streaming[index]!.shown >= 60 else { return nil }
                streaming[index]!.shown = streaming[index]!.text.count
            case "content_block_stop":
                if index == responseBlock { responseBlock = nil }
                guard let thought = streaming.removeValue(forKey: index), thought.shown < thought.text.count else { return nil }
                return .init(id: thought.id, title: "Pensando…", detail: thought.text, kind: .reasoning)
            default: return nil
            }
            guard let thought = streaming[index] else { return nil }
            return .init(id: thought.id, title: "Pensando…", detail: thought.text.isEmpty ? nil : thought.text, kind: .reasoning)
        case "result":
            usage = Self.usage(event, model: model)
            if let models = event["modelUsage"] as? [String: [String: Any]], let modelContext = models[context?.model ?? model]?["contextWindow"] as? Int, modelContext > 0 { context?.maxTokens = modelContext }
            let detail = String((event["result"] as? String ?? "").prefix(500))
            guard event["is_error"] as? Bool != true, event["subtype"] as? String == "success" else {
                throw MediaError.invalid(detail.isEmpty ? "Claude no completó la petición; revisa la cuenta/configuración y reintenta explícitamente." : "Claude: " + detail)
            }
            if let structured = event["structured_output"], !(structured is NSNull), JSONSerialization.isValidJSONObject(structured) {
                output = String(decoding: try JSONSerialization.data(withJSONObject: structured), as: UTF8.self)
            } else if !detail.isEmpty { output = event["result"] as? String }
            return .init(id: "provider-finished", title: compact ? "Contexto compactado" : "Comprobando respuesta…", context: context)
        default: return nil
        }
    }

    /// `modelUsage` names every model the request used; `usage` is the total.
    static func usage(_ event: [String: Any], model: String) -> [ProviderTokenUsage] {
        let count = ProviderTokenUsage.count
        if let models = event["modelUsage"] as? [String: [String: Any]], !models.isEmpty {
            return models.keys.sorted().map { name in
                let item = models[name]!
                return .init(model: name, input: count(item["inputTokens"]), cachedInput: count(item["cacheReadInputTokens"]), cacheWrite: count(item["cacheCreationInputTokens"]), output: count(item["outputTokens"]), reportedCost: (item["costUSD"] as? NSNumber)?.doubleValue)
            }.filter { $0.tokens > 0 }
        }
        guard let total = event["usage"] as? [String: Any] else { return [] }
        let value = ProviderTokenUsage(model: model.isEmpty ? "claude" : model, input: count(total["input_tokens"]), cachedInput: count(total["cache_read_input_tokens"]), cacheWrite: count(total["cache_creation_input_tokens"]), output: count(total["output_tokens"]), reportedCost: (event["total_cost_usd"] as? NSNumber)?.doubleValue)
        return value.tokens > 0 ? [value] : []
    }
}
