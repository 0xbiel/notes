import Foundation

public struct ProviderConnectionTestResult: Sendable {
    public let provider: NotesAIProvider
    public let model: String
    public let elapsedSeconds: Double
}

public enum ProviderConnectionTest {
    static let prompt = "Connection check. Reply only with {\"ok\":true}."

    public static func run(_ configuration: AIProviderConfiguration) async throws -> ProviderConnectionTestResult {
        try configuration.validate()
        try await ProviderRuntime.shared.prepare(configuration)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/notes-provider-tests/Connection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        var testConfiguration = configuration
        testConfiguration.accountSendingAllowed = true
        let store = LocalMediaStore(workspace: workspace)
        let started = Date()
        let reply: String
        switch configuration.provider {
        case .codexCLI:
            let transport = NotesProviderTransport(store: store)
            let directory = try transport.temporaryDirectory()
            let schema = directory.appendingPathComponent("schema.json")
            try Data(#"{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean","enum":[true]}}}"#.utf8).write(to: schema)
            let input = directory.appendingPathComponent("probe.txt")
            try Data(prompt.utf8).write(to: input)
            let instructions = directory.appendingPathComponent("instructions.txt")
            try Data("Return the requested JSON. Do not use tools.".utf8).write(to: instructions)
            var arguments = try NotesProviderTransport.codexArguments(testConfiguration, schema: schema, instructions: "Return the requested JSON. Do not use tools.")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            arguments.insert(contentsOf: ["--config", "model_instructions_file=" + String(decoding: try encoder.encode(instructions.path), as: UTF8.self)], at: arguments.count - 1)
            let events = try await transport.invoke(testConfiguration, arguments: arguments, input: input, directory: directory)
            reply = try NotesProviderTransport.decodeCodexText(events)
        case .claudeCode:
            let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["ok"], "properties": ["ok": ["type": "boolean", "enum": [true]]]]
            reply = try await ClaudeTextTransport(store: store, configuration: testConfiguration).generate(prompt, schema: schema, instructions: "Return the requested JSON. Do not use tools.")
        case .antigravity:
            reply = try await AntigravityTextTransport(store: store, configuration: testConfiguration).generate(prompt)
        case .openCode:
            reply = try await OpenRouterHarness(store: store, configuration: configuration).connectionProbe()
        }
        try validateReply(reply)
        try Task.checkCancellation()
        return .init(provider: configuration.provider, model: configuration.model, elapsedSeconds: Date().timeIntervalSince(started))
    }

    static func validateReply(_ reply: String) throws {
        guard reply.utf8.count <= 128,
              let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              Set(object.keys) == ["ok"], let value = object["ok"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else {
            throw MediaError.invalid("El proveedor no confirmó la conexión.")
        }
    }
}
