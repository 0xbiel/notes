import Foundation

/// Carries connection settings into isolated helpers without importing tools,
/// hooks, project instructions or plugins from the user's Codex configuration.
public enum CodexConnectionConfiguration {
    public struct Summary: Equatable, Sendable {
        public var providerID: String?
        public var providerName: String?
        public var baseURL: String?
        public var envKey: String?
        public init(providerID: String? = nil, providerName: String? = nil, baseURL: String? = nil, envKey: String? = nil) {
            self.providerID = providerID; self.providerName = providerName
            self.baseURL = baseURL; self.envKey = envKey
        }
        public var displayTitle: String? {
            let title = providerName ?? providerID
            if let title, !title.isEmpty, let baseURL, !baseURL.isEmpty { return "\(title) · \(baseURL)" }
            if let title, !title.isEmpty { return title }
            if let baseURL, !baseURL.isEmpty { return baseURL }
            return nil
        }
    }

    static func filtered(_ text: String) -> String {
        let keys: Set<String> = ["model_provider", "model", "openai_base_url", "chatgpt_base_url"]
        var providerSection = false
        var topLevel = true
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                topLevel = false
                providerSection = trimmed.hasPrefix("[model_providers.") && !trimmed.hasPrefix("[[")
                if providerSection { lines.append(line) }
            } else if providerSection {
                lines.append(line)
            } else if topLevel, let separator = trimmed.firstIndex(of: "="), keys.contains(trimmed[..<separator].trimmingCharacters(in: .whitespaces)) {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func parseSummary(_ text: String) -> Summary? {
        var providerID: String?
        var topBaseURL: String?
        var currentSection: String?
        var sectionNames: [String: String] = [:]
        var sectionURLs: [String: String] = [:]
        var sectionEnvKeys: [String: String] = [:]

        func unquote(_ raw: Substring) -> String {
            var value = raw.trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#"), !value.hasPrefix("\"") {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("[") {
                if trimmed.hasPrefix("[model_providers."), !trimmed.hasPrefix("[["), let closing = trimmed.firstIndex(of: "]") {
                    let start = trimmed.index(trimmed.startIndex, offsetBy: "[model_providers.".count)
                    currentSection = String(trimmed[start..<closing]).trimmingCharacters(in: .whitespaces)
                } else {
                    currentSection = ""
                }
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = unquote(trimmed[trimmed.index(after: separator)...])
            guard !value.isEmpty else { continue }
            if currentSection == nil {
                if key == "model_provider" { providerID = value }
                else if key == "openai_base_url" || key == "chatgpt_base_url" { topBaseURL = value }
            } else if let section = currentSection, !section.isEmpty {
                if key == "name" { sectionNames[section] = value }
                else if key == "base_url" { sectionURLs[section] = value }
                else if key == "env_key" { sectionEnvKeys[section] = value }
            }
        }
        let chosenSection = providerID ?? (sectionURLs.count == 1 ? sectionURLs.keys.first : nil)
        let name = chosenSection.flatMap { sectionNames[$0] }
        let baseURL = chosenSection.flatMap { sectionURLs[$0] } ?? topBaseURL
        let envKey = chosenSection.flatMap { sectionEnvKeys[$0] }
        guard providerID != nil || baseURL != nil else { return nil }
        return Summary(providerID: providerID, providerName: name, baseURL: baseURL, envKey: envKey)
    }

    public static func inspect(_ configuration: AIProviderConfiguration) -> Summary? {
        guard configuration.provider == .codexCLI else { return nil }
        let source = configuration.homePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") : URL(fileURLWithPath: configuration.homePath)
        let config = source.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        return parseSummary(text)
    }

    static func copy(_ configuration: AIProviderConfiguration, to home: URL) throws {
        let source = configuration.homePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") : URL(fileURLWithPath: configuration.homePath)
        let config = source.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        let content = filtered(try String(contentsOf: config, encoding: .utf8))
        let target = home.appendingPathComponent("config.toml")
        try Data(content.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
