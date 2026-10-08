import Foundation

public struct AIProviderModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var isDefault: Bool
    public var reasoning: [String]
    public init(id: String, name: String, detail: String = "", isDefault: Bool = false, reasoning: [String] = []) {
        self.id = id; self.name = name; self.detail = detail; self.isDefault = isDefault; self.reasoning = reasoning
    }
}

public struct AIProviderModelPreferences: Codable, Equatable, Sendable {
    public var favorites: [String] = []
    public var hidden: [String] = []
    public var order: [String] = []
    public var custom: [AIProviderModel] = []
    public init() {}
}

public enum ProviderModelCatalog {
    public static func codexCatalog(_ models: [AIProviderModel]) -> [AIProviderModel] {
        guard let source = models.first(where: { $0.id == "gpt-6-sol" }) else { return models }
        var result = models
        if let index = result.firstIndex(where: { $0.id == "gpt-6.1-sol" }) {
            result[index].reasoning = source.reasoning
        } else {
            result.append(.init(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", detail: "Configured model variant · reasoning options from GPT-6-Sol", reasoning: source.reasoning))
        }
        return result
    }

    public static func codexPage(_ response: [String: Any]) throws -> [AIProviderModel] {
        guard let rows = response["data"] as? [[String: Any]] else { throw MediaError.invalid("Catálogo Codex inválido.") }
        return try rows.filter { $0["hidden"] as? Bool != true }.map { row in
            guard let identifier = row["model"] as? String ?? row["id"] as? String else { throw MediaError.invalid("Modelo Codex sin identificador.") }
            try validateID(identifier)
            let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            return .init(id: identifier, name: row["displayName"] as? String ?? identifier, detail: row["description"] as? String ?? "", isDefault: row["isDefault"] as? Bool ?? false, reasoning: efforts)
        }
    }

    public static func antigravitySession(_ response: [String: Any]) throws -> [AIProviderModel] {
        let options = response["configOptions"] as? [[String: Any]] ?? []
        if let selection = options.first(where: { $0["id"] as? String == "model" }), let entries = selection["options"] as? [[String: Any]] {
            let flattened = entries.flatMap { entry in entry["options"] as? [[String: Any]] ?? [entry] }
            return try flattened.map { entry in
                guard let identifier = entry["value"] as? String else { throw MediaError.invalid("Modelo Antigravity sin identificador.") }
                try validateID(identifier)
                return .init(id: identifier, name: entry["name"] as? String ?? identifier, detail: entry["description"] as? String ?? "", isDefault: selection["currentValue"] as? String == identifier)
            }
        }
        if let models = response["models"] as? [String: Any], let rows = models["availableModels"] as? [[String: Any]] {
            return try rows.map { row in
                guard let identifier = row["modelId"] as? String else { throw MediaError.invalid("Modelo Antigravity sin identificador.") }
                try validateID(identifier)
                return .init(id: identifier, name: row["name"] as? String ?? identifier, detail: row["description"] as? String ?? "", isDefault: models["currentModelId"] as? String == identifier)
            }
        }
        throw MediaError.invalid("El proveedor no devolvió modelos disponibles.")
    }

    public static func validateID(_ identifier: String) throws {
        try AIProviderConfiguration(provider: .codexCLI, executablePath: "/unused", model: identifier).validate()
    }
}

extension NotesProviderTransport {
    public func models(_ configuration: AIProviderConfiguration) async throws -> [AIProviderModel] {
        try configuration.validate()
        if configuration.provider == .openCode {
            _ = try await diagnose(configuration)
            return [.init(id: OpenRouterHarness.model, name: "OpenRouter Free", detail: "Router gratuito configurado en Notes", isDefault: true)]
        }
        if configuration.provider == .antigravity { return try await AntigravityTextTransport(store: store, configuration: configuration).models() }
        let directory = try temporaryDirectory()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CODEX_") || key.hasPrefix("T3CODE_") { environment.removeValue(forKey: key) }
        if !configuration.homePath.isEmpty { environment["CODEX_HOME"] = configuration.homePath }
        let connection = ProviderRPCConnection(configuration: configuration, directory: directory, environment: environment, arguments: ["app-server", "--config", "mcp_servers={}", "--disable", "hooks"])
        return try await withTaskCancellationHandler {
            try await Task.detached {
                defer { connection.close() }
                try connection.start()
                _ = try connection.request("initialize", params: ["clientInfo": ["name": "notes-model-catalog", "version": "1.0"], "capabilities": ["experimentalApi": true]])
                try connection.notify("initialized")
                var catalog: [AIProviderModel] = []
                var cursor: String?
                var seen = Set<String>()
                for _ in 0..<20 {
                    let response = try connection.request("model/list", params: cursor.map { ["cursor": $0] } ?? [:])
                    catalog += try ProviderModelCatalog.codexPage(response)
                    guard let next = response["nextCursor"] as? String, !next.isEmpty else { return ProviderModelCatalog.codexCatalog(catalog) }
                    guard seen.insert(next).inserted else { throw MediaError.invalid("Paginación de modelos repetida.") }
                    cursor = next
                }
                throw MediaError.invalid("Catálogo de modelos demasiado grande.")
            }.value
        } onCancel: { connection.cancel() }
    }
}
