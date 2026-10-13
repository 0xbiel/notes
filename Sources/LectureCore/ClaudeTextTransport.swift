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
    public static func arguments(_ configuration: AIProviderConfiguration, schema: [String: Any], instructions: String, webSearch: Bool = false, imageInput: Bool = false) throws -> [String] {
        var settings: [String: Any] = ["disableAllHooks": true]
        if configuration.fastMode == true { settings["fastMode"] = true }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        var arguments = ["-p"] + (try ProviderLaunchArguments.resolve(configuration))
        arguments += ["--safe-mode", "--output-format", "stream-json", "--verbose"]
        if imageInput { arguments += ["--input-format", "stream-json"] }
        arguments += ["--json-schema", try json(schema), "--system-prompt", instructions, "--settings", try json(settings)]
        arguments += webSearch ? ["--tools", "WebSearch", "--allowedTools", "WebSearch"] : ["--tools", ""]
        arguments += ["--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk", "--no-session-persistence"]
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
    func generate(_ prompt: String, schema: [String: Any], instructions: String, images: [NotebookInputImage] = [], webSearch: Bool = false, checked: @escaping @Sendable () async -> Void = {}, usage: @escaping @Sendable (ProviderTokenUsage) -> Void = { _ in }, progress: @escaping @Sendable (NotebookProviderProgress) async -> Void = { _ in }) async throws -> String {
        try configuration.validateSending()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else { throw MediaError.invalid("No se encuentra el ejecutable. Selecciona una instalación existente; Palladium no instala proveedores.") }
        let directory = try NotesProviderTransport(store: store).temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.txt")
        try Self.input(prompt, images: images).write(to: input, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let command = try command(try Self.arguments(configuration, schema: schema, instructions: instructions, webSearch: webSearch, imageInput: !images.isEmpty), directory: directory, timeout: ProviderRequestLimits.generation)
        // The stream repeats the reply in its tool call, tool result and result.
        command.outputLimit = nil
        let reader = try FileHandle(forReadingFrom: input)
        command.process.standardInput = reader
        defer { try? reader.close() }
        await checked()
        let events = AsyncStream<NotebookProviderProgress>.makeStream()
        let state = ClaudeStreamState(webSearch: webSearch)
        let worker = Task.detached {
            defer { state.decoder.usage.forEach(usage); events.continuation.finish() }
            do {
                _ = try command.run { line in
                    // The first rejected event stops the helper; later lines are ignored.
                    guard state.failure == nil else { return }
                    do { if let update = try state.decoder.accept(line) { events.continuation.yield(update) } }
                    catch { state.failure = error; command.cancel() }
                }
            } catch {
                throw state.failure ?? error
            }
            if let failure = state.failure { throw failure }
            guard let output = state.decoder.output else { throw MediaError.invalid("Claude no devolvió una respuesta completa.") }
            return output
        }
        return try await withTaskCancellationHandler {
            for await event in events.stream { await progress(event) }
            return try await worker.value
        } onCancel: { command.cancel() }
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
    init(webSearch: Bool) { decoder = ClaudeStreamDecoder(webSearch: webSearch) }
}

/// Reads `--output-format stream-json` lines. The session must expose only the
/// structured-output tool (plus web search when the request allows it); any
/// other tool, MCP server or failed result rejects the response.
struct ClaudeStreamDecoder {
    var webSearch = false
    private(set) var output: String?
    /// Tokens per model, read from the final result even when it failed.
    private(set) var usage: [ProviderTokenUsage] = []
    private var model = ""
    private var thoughts = 0

    private var allowedTools: Set<String> { webSearch ? ["StructuredOutput", "WebSearch"] : ["StructuredOutput"] }

    mutating func accept(_ line: Data) throws -> NotebookProviderProgress? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String else { return nil }
        switch type {
        case "system":
            guard event["subtype"] as? String == "init" else { return nil }
            let tools = event["tools"] as? [String] ?? []
            let servers = event["mcp_servers"] as? [Any] ?? []
            model = event["model"] as? String ?? ""
            guard Set(tools).isSubset(of: allowedTools), servers.isEmpty else { throw MediaError.invalid("La sesión de Claude conserva herramientas o servidores MCP; no se ha enviado contenido.") }
            return .init(id: "provider-start", title: "Pensando…", kind: .reasoning)
        case "assistant":
            guard let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return nil }
            var update: NotebookProviderProgress?
            for block in blocks {
                switch block["type"] as? String {
                case "thinking":
                    thoughts += 1
                    let text = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    update = .init(id: "thought-\(thoughts)", title: "Pensando…", detail: text.isEmpty ? nil : text, kind: .reasoning)
                case "text": update = .init(id: "provider-response", title: "Redactando respuesta…")
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    guard allowedTools.contains(name) else { throw MediaError.invalid("Claude intentó usar una herramienta no permitida (\(name.prefix(60))); respuesta rechazada.") }
                    if name == "WebSearch" {
                        let query = (block["input"] as? [String: Any])?["query"] as? String
                        update = .init(id: "web-" + (block["id"] as? String ?? "current"), title: "Buscando en la web…", detail: query, kind: .tool)
                    } else { update = .init(id: "provider-response", title: "Redactando respuesta…") }
                default: continue
                }
            }
            return update
        case "result":
            usage = Self.usage(event, model: model)
            let detail = String((event["result"] as? String ?? "").prefix(500))
            guard event["is_error"] as? Bool != true, event["subtype"] as? String == "success" else {
                throw MediaError.invalid(detail.isEmpty ? "Claude no completó la petición; revisa la cuenta/configuración y reintenta explícitamente." : "Claude: " + detail)
            }
            if let structured = event["structured_output"], !(structured is NSNull), JSONSerialization.isValidJSONObject(structured) {
                output = String(decoding: try JSONSerialization.data(withJSONObject: structured), as: UTF8.self)
            } else if !detail.isEmpty { output = event["result"] as? String }
            return .init(id: "provider-finished", title: "Comprobando respuesta…")
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
