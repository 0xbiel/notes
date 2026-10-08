import Foundation

public enum NotesAIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openCode, codexCLI, antigravity
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openCode: "OpenCode · OpenRouter gratuito"
        case .codexCLI: "Codex CLI"
        case .antigravity: "Antigravity · ACP"
        }
    }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public var provider: NotesAIProvider
    public var executablePath: String
    public var model: String
    public var homePath: String
    public var harnessPath: String
    public var accountSendingAllowed: Bool
    public var reasoningEffort: String? = nil

    public init(provider: NotesAIProvider, executablePath: String, model: String = "default", homePath: String = "", harnessPath: String = "", accountSendingAllowed: Bool = false) {
        self.provider = provider; self.executablePath = executablePath; self.model = model
        self.homePath = homePath; self.harnessPath = harnessPath; self.accountSendingAllowed = accountSendingAllowed
    }

    public func validate() throws {
        if let reasoningEffort, !["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(reasoningEffort) { throw MediaError.invalid("Nivel de razonamiento inválido.") }
        guard executablePath.hasPrefix("/"), !executablePath.contains("\n"), !executablePath.contains("\0"),
              !model.isEmpty, model.count <= 160, model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:" )).contains($0) }) else {
            throw MediaError.invalid("Usa una ruta absoluta y un identificador de modelo válido, sin argumentos de shell.")
        }
        for path in [homePath, harnessPath] where !path.isEmpty {
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else { throw MediaError.invalid("Las rutas del proveedor deben ser absolutas.") }
        }
        if provider == .openCode, model != OpenRouterHarness.model { throw MediaError.invalid("OpenCode conserva el router gratuito y su política de privacidad/precio.") }
        if provider == .antigravity, homePath.isEmpty || harnessPath.isEmpty { throw MediaError.invalid("Selecciona el perfil autenticado y localharness_external de Antigravity ACP.") }
    }

    public func validateSending() throws {
        try validate()
        guard provider == .openCode || accountSendingAllowed else {
            throw MediaError.invalid("Autoriza explícitamente el envío por tu cuenta en Preferencias. Codex y Antigravity no garantizan coste cero ni retención cero.")
        }
    }
}

public struct AIProviderSettings: Codable, Equatable, Sendable {
    public var selectedProvider: NotesAIProvider = .openCode
    public var openCode: AIProviderConfiguration
    public var codexCLI: AIProviderConfiguration
    public var antigravity: AIProviderConfiguration
    public var modelPreferences: [String: AIProviderModelPreferences]? = nil

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let tools = home.appendingPathComponent(".t3/tools")
        let codex = Self.latestExecutable(in: tools.appendingPathComponent("codex"), suffix: "bin/codex") ?? "/opt/homebrew/bin/codex"
        let gravityRoot = tools.appendingPathComponent("antigravity-acp/darwin-arm64/versions")
        let gravity = Self.latestExecutable(in: gravityRoot, suffix: "agy_acp_server.par") ?? "/opt/homebrew/bin/antigravity-acp"
        let profileRoot = home.appendingPathComponent(".t3/userdata/providers/antigravity")
        let profiles = (try? FileManager.default.contentsOfDirectory(at: profileRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let profile = profiles.count == 1 ? profiles[0].path : ""
        openCode = .init(provider: .openCode, executablePath: "/opt/homebrew/bin/opencode", model: OpenRouterHarness.model)
        codexCLI = .init(provider: .codexCLI, executablePath: codex, homePath: home.appendingPathComponent(".codex").path)
        antigravity = .init(provider: .antigravity, executablePath: gravity, homePath: profile, harnessPath: URL(fileURLWithPath: gravity).deletingLastPathComponent().appendingPathComponent("localharness_external").path)
    }

    private static func latestExecutable(in root: URL, suffix: String) -> String? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent(suffix).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var selected: AIProviderConfiguration {
        get { configuration(for: selectedProvider) }
        set {
            switch selectedProvider {
            case .openCode: openCode = newValue
            case .codexCLI: codexCLI = newValue
            case .antigravity: antigravity = newValue
            }
        }
    }

    public func configuration(for provider: NotesAIProvider) -> AIProviderConfiguration {
        switch provider {
        case .openCode: openCode
        case .codexCLI: codexCLI
        case .antigravity: antigravity
        }
    }

    public func save(in workspace: SafeWorkspace) throws {
        for provider in NotesAIProvider.allCases {
            let config = configuration(for: provider)
            guard config.provider == provider else { throw MediaError.invalid("La configuración no coincide con el proveedor.") }
        }
        try selected.validate()
        try workspace.writeStorage("ai-provider-settings.json", data: JSONEncoder().encode(self))
    }

    public static func load(in workspace: SafeWorkspace) throws -> Self {
        guard FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent("ai-provider-settings.json").path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: workspace.readStorage("ai-provider-settings.json"))
        for provider in NotesAIProvider.allCases where value.configuration(for: provider).provider != provider { throw MediaError.invalid("Configuración de proveedor incoherente.") }
        return value
    }
}

public struct AIProviderDiagnostic: Sendable {
    public var message: String
    public var models: [String]
    public init(message: String, models: [String] = []) { self.message = message; self.models = models }
}
