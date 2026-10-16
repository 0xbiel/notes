import Foundation

public struct AIProviderModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var isDefault: Bool
    public var reasoning: [String]
    public var supportsFastMode: Bool? = nil
    public var defaultReasoningEffort: String? = nil
    public init(id: String, name: String, detail: String = "", isDefault: Bool = false, reasoning: [String] = [], supportsFastMode: Bool? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.isDefault = isDefault; self.reasoning = reasoning; self.supportsFastMode = supportsFastMode
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
            let tiers = row["serviceTiers"] as? [[String: Any]] ?? []
            let fast = (row["additionalSpeedTiers"] as? [String] ?? []).contains("fast") || tiers.contains { ["fast", "priority"].contains($0["id"] as? String ?? "") }
            var model = AIProviderModel(id: identifier, name: row["displayName"] as? String ?? identifier, detail: row["description"] as? String ?? "", isDefault: row["isDefault"] as? Bool ?? false, reasoning: efforts, supportsFastMode: fast)
            model.defaultReasoningEffort = row["defaultReasoningEffort"] as? String
            return model
        }
    }

    /// Antigravity lists one entry per thinking level ("Gemini 3.8 Flash (High)",
    /// gemini-3.8-flash-high). The app shows each model once, with those levels as its reasoning.
    public static func antigravitySession(_ response: [String: Any]) throws -> [AIProviderModel] {
        antigravityGrouped(try antigravityVariants(response))
    }

    /// The session's entries as Antigravity names them, one per thinking level.
    public static func antigravityVariants(_ response: [String: Any]) throws -> [AIProviderModel] {
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

    static let antigravityEfforts = ["low", "medium", "high"]

    /// "gemini-3.8-flash-high" is the model "gemini-3.8-flash" at the "high" level.
    public static func antigravityVariant(_ identifier: String) -> (model: String, effort: String)? {
        for effort in antigravityEfforts where identifier.hasSuffix("-" + effort) && identifier.count > effort.count + 1 {
            return (String(identifier.dropLast(effort.count + 1)), effort)
        }
        return nil
    }

    static func antigravityGrouped(_ variants: [AIProviderModel]) -> [AIProviderModel] {
        var result: [AIProviderModel] = [], positions: [String: Int] = [:]
        for variant in variants {
            guard let (identifier, effort) = antigravityVariant(variant.id) else { result.append(variant); continue }
            if let position = positions[identifier] {
                result[position].reasoning.append(effort)
                if variant.isDefault { result[position].isDefault = true; result[position].defaultReasoningEffort = effort }
                continue
            }
            let name = variant.name.replacingOccurrences(of: #"\s*\((Low|Medium|High)\)$"#, with: "", options: .regularExpression)
            var model = AIProviderModel(id: identifier, name: name, isDefault: variant.isDefault, reasoning: [effort])
            if variant.isDefault { model.defaultReasoningEffort = effort }
            positions[identifier] = result.count
            result.append(model)
        }
        for position in positions.values {
            result[position].reasoning.sort { antigravityEfforts.firstIndex(of: $0)! < antigravityEfforts.firstIndex(of: $1)! }
            // A model offered at one level only has nothing to choose.
            if result[position].reasoning.count == 1 { result[position].reasoning = [] }
        }
        return result
    }

    /// The entry to ask the session for: the chosen level of the model, else the
    /// level the session already uses, else Medium. Older settings naming an entry keep it.
    public static func antigravityEntry(_ model: String, effort: String?, entries: [String], current: String?) -> String {
        if entries.contains(model) { return model }
        let levels = entries.filter { antigravityVariant($0)?.model == model }
        guard !levels.isEmpty else { return model }
        if let effort, levels.contains(model + "-" + effort) { return model + "-" + effort }
        if let current, levels.contains(current) { return current }
        return levels.first { $0 == model + "-medium" } ?? levels[levels.count / 2]
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
            return [.init(id: OpenRouterHarness.model, name: "OpenRouter Free", detail: "Router gratuito configurado en Palladium", isDefault: true)]
        }
        if configuration.provider == .antigravity { return try await AntigravityTextTransport(store: store, configuration: configuration).models() }
        if configuration.provider == .claudeCode { return try await ClaudeTextTransport(store: store, configuration: configuration).models() }
        let environment = try Self.codexEnvironment(configuration)
        let directory = try temporaryDirectory()
        let connection = ProviderRPCConnection(configuration: configuration, directory: directory, environment: environment, arguments: ["app-server"] + (try ProviderLaunchArguments.resolve(configuration)) + ["--config", "mcp_servers={}", "--disable", "hooks"])
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
