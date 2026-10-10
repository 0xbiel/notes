import Foundation
import Security

/// Provider credentials entered in Preferences. Like the transcription key,
/// they never enter settings files, queued batches or request logs.
public enum ProviderSecrets {
    public static let antigravityAPIKey = "setting/apiKey"
    public static func environmentName(_ name: String) -> String { "env/" + name }

    private static func query(_ provider: NotesAIProvider, _ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Palladium.Providers", kSecAttrAccount as String: provider.rawValue + "/" + name]
    }
    public static func read(_ provider: NotesAIProvider, _ name: String) throws -> String? {
        var q = query(provider, name); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let secret = String(data: data, encoding: .utf8) else { throw MediaError.invalid("No se pudo acceder al llavero del proveedor.") }
        return secret
    }
    /// An empty value removes the stored secret.
    public static func save(_ value: String, provider: NotesAIProvider, name: String) throws {
        let query = query(provider, name)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MediaError.invalid("No se pudo eliminar el secreto del llavero.") }; return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MediaError.invalid("No se pudo guardar el secreto en el llavero.") }
    }
}

public enum ProviderEnvironment {
    public typealias SecretReader = @Sendable (NotesAIProvider, String) throws -> String?

    public static func validate(_ variables: [AIProviderEnvironmentVariable]) throws {
        guard variables.count <= 64, Set(variables.map(\.name)).count == variables.count else { throw MediaError.invalid("Variables de entorno duplicadas o excesivas.") }
        for variable in variables {
            guard variable.name.count <= 128, variable.name.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil else {
                throw MediaError.invalid("Nombre de variable de entorno inválido: " + String(variable.name.prefix(40)))
            }
            guard variable.value.utf8.count <= 8_192, !variable.value.contains("\0") else { throw MediaError.invalid("Valor de variable de entorno inválido: " + variable.name) }
            // A sensitive value in settings would also be copied into queued batches.
            guard !variable.sensitive || variable.value.isEmpty else { throw MediaError.invalid("Los valores sensibles se guardan en el llavero: " + variable.name) }
        }
    }

    /// Adds the instance variables to a process environment. Transports apply
    /// this before the variables they enforce, so isolation settings prevail.
    public static func apply(_ configuration: AIProviderConfiguration, to environment: inout [String: String], secret: SecretReader = { try ProviderSecrets.read($0, $1) }) throws {
        let variables = configuration.environment ?? []
        try validate(variables)
        for variable in variables {
            guard variable.sensitive else { environment[variable.name] = variable.value; continue }
            guard let value = try secret(configuration.provider, ProviderSecrets.environmentName(variable.name)), !value.isEmpty else {
                throw MediaError.invalid("Falta el valor sensible de \(variable.name). Introdúcelo de nuevo en Proveedores.")
            }
            environment[variable.name] = value
        }
    }
}

public enum ProviderLaunchArguments {
    /// Options Palladium sets itself for every Claude request. Accepting them
    /// from settings could add tools, directories or another output protocol.
    static let claudeManaged: Set<String> = [
        "-p", "--print", "--output-format", "--input-format", "--json-schema", "--include-partial-messages", "--replay-user-messages",
        "--system-prompt", "--system-prompt-file", "--append-system-prompt", "--append-system-prompt-file",
        "--tools", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
        "--permission-mode", "--permission-prompts", "--permission-prompt-tool", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
        "--mcp-config", "--add-dir", "--plugin-dir", "--plugin-url", "--agents", "--agent", "--chrome", "--ide", "--settings", "--setting-sources",
        "--model", "--effort", "--autocompact", "-c", "--continue", "-r", "--resume", "--session-id", "--fork-session", "--from-pr",
        "--bg", "--background", "--cloud", "--desktop", "--remote-control", "--teleport", "--tmux", "--environment"
    ]
    static let codexManagedKeys: Set<String> = [
        "approval_policy", "web_search", "mcp_servers", "project_doc_max_bytes", "developer_instructions", "sandbox_mode",
        "model", "model_reasoning_effort", "service_tier", "cli_auth_credentials_store", "model_instructions_file"
    ]

    public static func tokenize(_ text: String) throws -> [String] {
        guard !text.contains("\0"), text.utf8.count <= 4_000 else { throw MediaError.invalid("Argumentos de lanzamiento inválidos.") }
        var tokens: [String] = []; var current = ""; var quote: Character?; var open = false; var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; open = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; open = true; continue }
            if character.isWhitespace {
                if open { tokens.append(current); current = ""; open = false }
                continue
            }
            current.append(character); open = true
        }
        guard quote == nil, !escaped else { throw MediaError.invalid("Argumentos de lanzamiento con comillas sin cerrar.") }
        if open { tokens.append(current) }
        return tokens
    }

    /// The extra arguments this provider accepts, or an error naming the first
    /// one Palladium manages itself.
    public static func resolve(_ configuration: AIProviderConfiguration) throws -> [String] {
        let tokens = try tokenize(configuration.launchArguments ?? "")
        switch configuration.provider {
        case .openCode, .antigravity: return []
        case .claudeCode:
            for token in tokens where token.hasPrefix("-") {
                let flag = String(token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                guard !claudeManaged.contains(flag) else { throw MediaError.invalid("Palladium gestiona \(flag) en cada petición; quítalo de los argumentos de lanzamiento.") }
            }
            return tokens
        case .codexCLI:
            var result: [String] = []; var index = 0
            func managed(_ flag: String, _ value: String) -> Bool {
                let key = String(value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                if flag == "--config" { return codexManagedKeys.contains(key) || ["features.", "skills.", "mcp_servers."].contains { key.hasPrefix($0) } }
                return flag == "--enable" && NotesProviderTransport.codexDisabledFeatures.contains(key)
            }
            while index < tokens.count {
                var flag = tokens[index]; var value: String?
                if let separator = flag.firstIndex(of: "="), flag.hasPrefix("-") { value = String(flag[flag.index(after: separator)...]); flag = String(flag[..<separator]) }
                if flag == "-c" { flag = "--config" }
                index += 1
                if flag == "--strict-config", value == nil { result.append(flag); continue }
                guard ["--config", "--enable", "--disable"].contains(flag) else { throw MediaError.invalid("Codex admite aquí --config, --enable, --disable y --strict-config; sobra \(tokens[index - 1].prefix(40)).") }
                if value == nil, index < tokens.count { value = tokens[index]; index += 1 }
                guard let value, !value.isEmpty, !value.hasPrefix("-") else { throw MediaError.invalid("Falta el valor de \(flag) en los argumentos de lanzamiento.") }
                guard !managed(flag, value) else { throw MediaError.invalid("Palladium gestiona \(flag) \(value.prefix(40)) en cada petición; quítalo de los argumentos de lanzamiento.") }
                result += [flag, value]
            }
            return result
        }
    }
}
