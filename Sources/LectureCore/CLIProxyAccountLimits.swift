import Foundation

/// The dashboard exposes sanitized account metadata and cached quota snapshots.
/// No auth files, access tokens or management credentials are read by Palladium.
public enum CLIProxyAccountLimits {
    public static func dashboardURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else { return nil }
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/api/state" }
        return parts.url
    }

    public static func endpoint(_ configuration: AIProviderConfiguration) -> URL? {
        if let custom = configuration.proxyUsageURL, !custom.isEmpty { return dashboardURL(custom) }
        guard configuration.provider != .openCode else { return nil }
        let source = connection(configuration)
        guard source.knownWrapper || source.localStandard || source.namedProxy && source.baseURL == nil else { return nil }
        return URL(string: "http://127.0.0.1:8318/api/state")
    }

    static func isProxy(_ configuration: AIProviderConfiguration) -> Bool {
        let source = connection(configuration)
        return configuration.proxyUsageURL?.isEmpty == false || source.knownWrapper || source.localStandard || source.namedProxy
    }

    private static func connection(_ configuration: AIProviderConfiguration) -> (knownWrapper: Bool, localStandard: Bool, namedProxy: Bool, baseURL: URL?) {
        let summary = CodexConnectionConfiguration.inspect(configuration)
        let providerName = ((summary?.providerID ?? "") + " " + (summary?.providerName ?? "")).lowercased()
        let base = summary?.baseURL ?? (configuration.environment ?? []).first { ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "CODEX_BASE_URL"].contains($0.name) && !$0.sensitive }?.value
        let baseURL = base.flatMap(URL.init(string:))
        let local = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(baseURL?.host?.lowercased() ?? "")
        let wrapper = URL(fileURLWithPath: configuration.executablePath)
        let knownWrapper = wrapper.pathComponents.contains("CLIProxyAPI") && ["codex-proxy", "claude-proxy"].contains(wrapper.lastPathComponent)
        return (knownWrapper, local && baseURL?.port == 8317, providerName.contains("cliproxy"), baseURL)
    }

    static func read(_ configuration: AIProviderConfiguration, endpoint: URL, session: URLSession? = nil) async throws -> ProviderLimits {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 10; settings.timeoutIntervalForResource = 15
        settings.httpShouldSetCookies = false
        let client = session ?? URLSession(configuration: settings)
        defer { if session == nil { client.finishTasksAndInvalidate() } }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await client.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["accounts"] is [[String: Any]] else {
            throw MediaError.invalid("CLIProxyAPI no devolvió los límites de sus cuentas.")
        }
        return parse(object, configuration: configuration)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func milliseconds(_ value: Any?) -> Date? {
        guard let value = number(value), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1_000)
    }
    private static func masked(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"[^\s@]+@[^\s@]+"#) else { return String(text.prefix(80)) }
        let mutable = NSMutableString(string: String(text.prefix(160)))
        for match in pattern.matches(in: mutable as String, range: NSRange(location: 0, length: mutable.length)).reversed() {
            let email = mutable.substring(with: match.range)
            let parts = email.split(separator: "@", maxSplits: 1)
            mutable.replaceCharacters(in: match.range, with: String(parts[0].prefix(1)) + "•••@" + parts[1])
        }
        return String((mutable as String).prefix(80))
    }

    static func parse(_ payload: [String: Any], configuration: AIProviderConfiguration, now: Date = Date()) -> ProviderLimits {
        var result = ProviderLimits(provider: configuration.provider, name: configuration.name)
        result.source = "CLIProxyAPI"; result.checked = now
        let provider: String
        switch configuration.provider {
        case .codexCLI: provider = "codex"
        case .claudeCode: provider = "claude"
        case .antigravity: provider = "antigravity"
        case .openCode: return result
        }
        var seen = Set<String>()
        for account in payload["accounts"] as? [[String: Any]] ?? [] {
            let type = account["provider"] as? String
            guard type == provider || provider == "claude" && type == "anthropic",
                  let id = account["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            let quota = account["quota"] as? [String: Any] ?? [:]
            let label = (account["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = [label, email].compactMap { $0 }.first { !$0.isEmpty } ?? "CLIProxyAPI \(result.accounts.count + 1)"
            let checked = milliseconds(quota["checkedAt"])
            var windows: [ProviderLimitWindow] = []
            for (index, window) in (quota["windows"] as? [[String: Any]] ?? []).enumerated() {
                // Unknown/malformed percentages are unavailable, never 100% left.
                guard let remaining = number(window["remaining"]), (0...100).contains(remaining) else { continue }
                let duration = number(window["duration"])
                let kind: ProviderLimitWindow.Kind
                if let duration, duration > 0 {
                    kind = duration <= 86_400 ? .session : duration <= 604_800 ? .weekly : .monthly
                } else {
                    switch window["kind"] as? String {
                    case "short", "session": kind = .session
                    case "monthly": kind = .monthly
                    case "weekly": kind = (window["label"] as? String)?.lowercased().contains("month") == true ? .monthly : .weekly
                    default: kind = .other
                    }
                }
                windows.append(.init(id: id + "-" + String(index), kind: kind, scope: kind == .other ? window["label"] as? String : nil, usedPercent: 100 - remaining, resetsAt: milliseconds(window["resetAt"])))
            }
            let message: String?
            if account["disabled"] as? Bool == true { message = "Cuenta pausada en CLIProxyAPI." }
            else if quota["error"] as? String != nil || checked == nil || now.timeIntervalSince(checked ?? .distantPast) > 600 || payload["connected"] as? Bool == false {
                message = windows.isEmpty ? "No hay límites recientes para esta cuenta." : "Los límites guardados pueden estar desactualizados."
            } else if account["unavailable"] as? Bool == true { message = "Cuenta temporalmente no disponible en CLIProxyAPI." }
            else if quota["allowed"] as? Bool == false { message = "Límite de la cuenta alcanzado." }
            else { message = windows.isEmpty ? "Esta cuenta no publica límites." : nil }
            result.accounts.append(.init(id: id, name: masked(name), plan: quota["plan"] as? String ?? account["plan"] as? String, windows: windows, checked: checked, message: message))
        }
        if result.accounts.isEmpty { result.message = "CLIProxyAPI no tiene cuentas de este proveedor con límites disponibles." }
        else if payload["connected"] as? Bool == false { result.message = "El panel de CLIProxyAPI no está conectado al proxy. Se muestran sus últimos datos guardados." }
        return result
    }
}
