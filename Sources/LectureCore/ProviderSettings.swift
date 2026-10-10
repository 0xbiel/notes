import Foundation

public enum NotesAIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openCode, codexCLI, claudeCode, antigravity
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openCode: "OpenCode · OpenRouter gratuito"
        case .codexCLI: "Codex CLI"
        case .claudeCode: "Claude Code"
        case .antigravity: "Antigravity · ACP"
        }
    }
    public var shortName: String {
        switch self {
        case .openCode: "OpenCode"
        case .codexCLI: "Codex"
        case .claudeCode: "Claude"
        case .antigravity: "Antigravity"
        }
    }
    /// Providers whose catalogs publish reasoning levels and speed tiers.
    public var supportsReasoning: Bool { self == .codexCLI || self == .claudeCode }
    public var supportsNativeWebSearch: Bool { self == .codexCLI || self == .claudeCode }
    public var supportsCustomModels: Bool { self != .openCode }
}

/// One variable passed to the provider process. Sensitive values live in the
/// Keychain (`ProviderSecrets`), never in settings or queued batches.
public struct AIProviderEnvironmentVariable: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var value: String
    public var sensitive: Bool
    public var id: String { name }
    public init(name: String, value: String = "", sensitive: Bool = false) {
        self.name = name; self.value = value; self.sensitive = sensitive
    }
}

public enum AntigravityAuthMethod: String, CaseIterable, Sendable {
    case personal = "oauth-personal", business = "oauth-business", apiKey = "gemini-api-key", agentPlatform = "agent-platform"
    public var usesBrowserLogin: Bool { self == .personal || self == .business }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public var provider: NotesAIProvider
    public var executablePath: String
    public var model: String
    public var homePath: String
    public var harnessPath: String
    public var accountSendingAllowed: Bool
    public var reasoningEffort: String? = nil
    public var fastMode: Bool? = nil
    public var openRouterAllowRetention: Bool? = nil
    public var displayName: String? = nil
    public var accentColor: String? = nil
    public var environment: [AIProviderEnvironmentVariable]? = nil
    public var launchArguments: String? = nil
    /// Codex: account-specific home holding `auth.json`.
    public var shadowHomePath: String? = nil
    /// Claude: compact after this many tokens (100,000–1,000,000).
    public var autoCompactWindow: String? = nil
    /// Antigravity sign-in method and Google Cloud target.
    public var authMethod: String? = nil
    public var gcpProject: String? = nil
    public var gcpLocation: String? = nil

    public init(provider: NotesAIProvider, executablePath: String, model: String = "default", homePath: String = "", harnessPath: String = "", accountSendingAllowed: Bool = true) {
        self.provider = provider; self.executablePath = executablePath; self.model = model
        self.homePath = homePath; self.harnessPath = harnessPath; self.accountSendingAllowed = accountSendingAllowed
    }

    public var name: String {
        let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? provider.shortName : custom
    }
    public var antigravityAuth: AntigravityAuthMethod { authMethod.flatMap(AntigravityAuthMethod.init(rawValue:)) ?? .personal }
    /// Where the account credentials are read from.
    public var accountHomePath: String {
        let shadow = shadowHomePath ?? ""
        return provider == .codexCLI && !shadow.isEmpty ? shadow : homePath
    }

    public func validate() throws {
        if let reasoningEffort, !["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(reasoningEffort) { throw MediaError.invalid("Nivel de razonamiento inválido.") }
        guard executablePath.hasPrefix("/"), !executablePath.contains("\n"), !executablePath.contains("\0"),
              !model.isEmpty, model.count <= 160, model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:" )).contains($0) }) else {
            throw MediaError.invalid("Usa una ruta absoluta y un identificador de modelo válido, sin argumentos de shell.")
        }
        for path in [homePath, harnessPath, shadowHomePath ?? ""] where !path.isEmpty {
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else { throw MediaError.invalid("Las rutas del proveedor deben ser absolutas.") }
        }
        if provider == .openCode, model != OpenRouterHarness.model { throw MediaError.invalid("OpenCode conserva el router gratuito y su política de privacidad/precio.") }
        if provider == .antigravity, homePath.isEmpty || harnessPath.isEmpty { throw MediaError.invalid("Selecciona el perfil autenticado y localharness_external de Antigravity ACP.") }
        if let displayName, displayName.count > 60 || displayName.contains("\n") { throw MediaError.invalid("El nombre del proveedor es demasiado largo.") }
        if let accentColor, accentColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { throw MediaError.invalid("Color de proveedor inválido.") }
        if let window = autoCompactWindow, !window.isEmpty {
            guard provider == .claudeCode, let tokens = Int(window), String(tokens) == window, (100_000...1_000_000).contains(tokens) else {
                throw MediaError.invalid("La compactación automática admite de 100000 a 1000000 tokens.")
            }
        }
        if let authMethod {
            guard provider == .antigravity, AntigravityAuthMethod(rawValue: authMethod) != nil else { throw MediaError.invalid("Método de inicio de sesión inválido.") }
        }
        for value in [gcpProject ?? "", gcpLocation ?? ""] where !value.isEmpty {
            guard provider == .antigravity, value.count <= 128, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:")).contains($0) }) else {
                throw MediaError.invalid("Proyecto o región de Google Cloud inválidos.")
            }
        }
        try ProviderEnvironment.validate(environment ?? [])
        _ = try ProviderLaunchArguments.resolve(self)
    }

    public func validateSending() throws {
        try validate()
        guard accountSendingAllowed else {
            throw MediaError.invalid("Este proveedor está desactivado. Actívalo en Preferencias.")
        }
    }
}

public enum AIEditAutonomy: String, Codable, CaseIterable, Sendable {
    case review, additions, edits
    public func allows(_ action: AIAction) -> Bool {
        switch self {
        case .review: false
        case .additions: action == .add || action == .priority
        case .edits: [.add, .priority, .correct, .retract].contains(action)
        }
    }
}

public struct AIProviderSettings: Codable, Equatable, Sendable {
    public var selectedProvider: NotesAIProvider = .openCode
    public var editAutonomy: AIEditAutonomy? = nil
    public var openCode: AIProviderConfiguration
    public var codexCLI: AIProviderConfiguration
    public var claudeCode: AIProviderConfiguration
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
        let claudeCandidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claude = claudeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? claudeCandidates[0]
        openCode = .init(provider: .openCode, executablePath: "/opt/homebrew/bin/opencode", model: OpenRouterHarness.model)
        codexCLI = .init(provider: .codexCLI, executablePath: codex, homePath: home.appendingPathComponent(".codex").path)
        // An empty config directory keeps Claude Code's own default and login.
        claudeCode = .init(provider: .claudeCode, executablePath: claude)
        antigravity = .init(provider: .antigravity, executablePath: gravity, homePath: profile, harnessPath: URL(fileURLWithPath: gravity).deletingLastPathComponent().appendingPathComponent("localharness_external").path)
    }

    /// Settings saved before a provider existed keep loading with its defaults.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        selectedProvider = try values.decode(NotesAIProvider.self, forKey: .selectedProvider)
        editAutonomy = try values.decodeIfPresent(AIEditAutonomy.self, forKey: .editAutonomy)
        openCode = try values.decode(AIProviderConfiguration.self, forKey: .openCode)
        codexCLI = try values.decode(AIProviderConfiguration.self, forKey: .codexCLI)
        claudeCode = try values.decodeIfPresent(AIProviderConfiguration.self, forKey: .claudeCode) ?? defaults.claudeCode
        antigravity = try values.decode(AIProviderConfiguration.self, forKey: .antigravity)
        modelPreferences = try values.decodeIfPresent([String: AIProviderModelPreferences].self, forKey: .modelPreferences)
    }

    private static func latestExecutable(in root: URL, suffix: String) -> String? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent(suffix).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var selected: AIProviderConfiguration {
        get { configuration(for: selectedProvider) }
        set { self[selectedProvider] = newValue }
    }

    public subscript(provider: NotesAIProvider) -> AIProviderConfiguration {
        get { configuration(for: provider) }
        set {
            switch provider {
            case .openCode: openCode = newValue
            case .codexCLI: codexCLI = newValue
            case .claudeCode: claudeCode = newValue
            case .antigravity: antigravity = newValue
            }
        }
    }

    public func configuration(for provider: NotesAIProvider) -> AIProviderConfiguration {
        switch provider {
        case .openCode: openCode
        case .codexCLI: codexCLI
        case .claudeCode: claudeCode
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
    public var version: String?
    public init(message: String, models: [String] = [], version: String? = nil) { self.message = message; self.models = models; self.version = version }
}
