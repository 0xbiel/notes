import Foundation

public struct NotesProviderTransport: Sendable {
    public let store: LocalMediaStore
    public init(store: LocalMediaStore) { self.store = store }

    public func diagnose(_ configuration: AIProviderConfiguration) async throws -> AIProviderDiagnostic {
        try configuration.validate()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else { throw MediaError.invalid("No se encuentra el ejecutable. Selecciona una instalación existente; Palladium no instala proveedores.") }
        switch configuration.provider {
        case .openCode:
            let harness = OpenRouterHarness(store: store, executablePath: configuration.executablePath)
            try await harness.prepare()
            return .init(message: "OpenCode compatible · configuración efectiva verificada · router gratuito · sin envío", models: [OpenRouterHarness.model])
        case .codexCLI:
            let version = try await invoke(configuration, arguments: ["--version"])
            let help = String(decoding: try await invoke(configuration, arguments: ["exec", "--help"]), as: UTF8.self)
            guard help.contains("--ignore-user-config"), help.contains("--ignore-rules"), help.contains("--ephemeral"), help.contains("--output-schema"), help.contains("--json") else { throw MediaError.invalid("Codex CLI no ofrece el transporte aislado requerido. Actualiza su instalación fuera de Palladium.") }
            return .init(message: String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) + " · exec JSON disponible · no comprueba login ni envía texto")
        case .antigravity:
            return try await AntigravityTextTransport(store: store, configuration: configuration).diagnose()
        }
    }

    public func send(_ batch: AIBatch, configuration: AIProviderConfiguration, checked: @escaping @Sendable () async -> Void = {}) async throws -> AIBatch {
        try configuration.validateSending()
        if configuration.provider == .openCode {
            let harness = OpenRouterHarness(store: store, executablePath: configuration.executablePath)
            if batch.syntheticDemoProvenance == SyntheticAIFixture.version { return try await harness.sendSyntheticDemo(batch, checked: checked) }
            return try await harness.send(batch, checked: checked)
        }
        if configuration.provider == .antigravity {
            return try await AntigravityTextTransport(store: store, configuration: configuration).send(batch, checked: checked)
        }
        _ = try await diagnose(configuration)
        try Task.checkCancellation()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = directory.appendingPathComponent("response-schema.json")
        try JSONSerialization.data(withJSONObject: Self.responseSchema, options: [.sortedKeys]).write(to: schema, options: .withoutOverwriting)
        let input = directory.appendingPathComponent("input.txt")
        try OpenRouterHarness.payload(batch).write(to: input, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        await checked()
        let data = try await invoke(configuration, arguments: Self.codexArguments(configuration, schema: schema), input: input, directory: directory)
        return try Self.decodeCodexEvents(data, for: batch)
    }

    func temporaryDirectory() throws -> URL {
        let path = store.root.appendingPathComponent(".provider-helper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }

    func invoke(_ configuration: AIProviderConfiguration, arguments: [String], input: URL? = nil, directory: URL? = nil) async throws -> Data {
        let command = NotesProcess(timeoutInterval: input == nil ? ProviderRequestLimits.diagnostic : ProviderRequestLimits.generation)
        command.process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        command.process.arguments = arguments
        command.process.currentDirectoryURL = directory ?? store.root
        var environment = ProcessInfo.processInfo.environment
        for name in environment.keys where name.hasPrefix("CODEX_") || name.hasPrefix("T3CODE_") { environment.removeValue(forKey: name) }
        if !configuration.homePath.isEmpty { environment["CODEX_HOME"] = configuration.homePath }
        command.process.environment = environment
        let reader = try input.map { try FileHandle(forReadingFrom: $0) }
        command.process.standardInput = reader ?? FileHandle.nullDevice
        defer { try? reader?.close() }
        return try await withTaskCancellationHandler {
            try await Task.detached { try command.run() }.value
        } onCancel: { command.cancel() }
    }

    public static func codexArguments(_ configuration: AIProviderConfiguration, schema: URL, instructions: String = OpenRouterHarness.systemPrompt, allowWebSearch: Bool = false) -> [String] {
        var arguments = ["exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only", "--json", "--color", "never", "--output-schema", schema.path,
                         "--config", "approval_policy=\"never\"", "--config", allowWebSearch ? "web_search=\"live\"" : "web_search=\"disabled\"", "--config", "mcp_servers={}",
                         "--config", "project_doc_max_bytes=0", "--config", "skills.bundled.enabled=false", "--config", "skills.include_instructions=false",
                         "--config", "developer_instructions=" + tomlString(instructions)]
        for feature in ["shell_tool", "unified_exec", "multi_agent", "multi_agent_v2", "apps", "hooks", "browser_use", "computer_use", "code_mode", "code_mode_only", "code_mode_prewarm", "skill_search"] {
            arguments += ["--disable", feature]
        }
        if configuration.model != "default" { arguments += ["--model", configuration.model] }
        if configuration.fastMode == true { arguments += ["--config", "service_tier=\"fast\""] }
        if let effort = configuration.reasoningEffort { arguments += ["--config", "model_reasoning_effort=" + tomlString(effort)] }
        return arguments + ["-"]
    }

    private static func tomlString(_ value: String) -> String {
        let encoded = try? JSONEncoder().encode(value)
        return encoded.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    public static var responseSchema: [String: Any] {
        let decision: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["source_ids", "action", "text", "reason", "target_quote"], "properties": ["source_ids": ["type": "array", "items": ["type": "string"]], "action": ["type": "string", "enum": ["add", "correct", "retract", "omit", "aside", "priority", "uncertain"]], "text": ["type": "string"], "reason": ["type": "string"], "target_quote": ["type": ["string", "null"]]]]
        return ["type": "object", "additionalProperties": false, "required": ["version", "batch_id", "decisions"], "properties": ["version": ["type": "integer", "enum": [1]], "batch_id": ["type": "string"], "decisions": ["type": "array", "items": decision]]]
    }

    public static func decodeCodexEvents(_ data: Data, for batch: AIBatch) throws -> AIBatch {
        let text = try decodeCodexText(data)
        var result = batch
        result.decisions = try OpenRouterHarness.decodeResponse(text, for: batch)
        result.stage = .ready; result.error = nil; result.reportedCost = nil
        return result
    }

    static func decodeCodexText(_ data: Data) throws -> String {
        guard data.count <= 2_000_000, let lines = String(data: data, encoding: .utf8) else { throw MediaError.invalid("Salida Codex inválida.") }
        var text = ""; var completed = false
        for line in lines.split(separator: "\n") {
            guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = event["type"] as? String else { throw MediaError.invalid("Evento Codex inválido.") }
            if type == "error" || type == "turn.failed" { throw MediaError.invalid("Codex no completó el lote; revisa la cuenta/configuración y reintenta explícitamente.") }
            if type.hasPrefix("item."), let item = event["item"] as? [String: Any], let itemType = item["type"] as? String {
                if itemType == "error" { throw MediaError.invalid("Codex: " + String((item["message"] as? String ?? "La cuenta no pudo completar la petición.").prefix(500))) }
                guard ["agent_message", "reasoning"].contains(itemType) else { throw MediaError.invalid("Codex devolvió un evento no permitido (\(itemType.prefix(60))); respuesta rechazada.") }
                if type == "item.completed", itemType == "agent_message", let content = item["text"] as? String { text = content }
            }
            if type == "turn.completed" { completed = true }
        }
        guard completed, !text.isEmpty else { throw MediaError.invalid("Codex no devolvió una respuesta completa.") }
        return text
    }
}
