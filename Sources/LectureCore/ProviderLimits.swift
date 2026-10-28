import Foundation

/// One rolling allowance of a subscription, as its provider reports it.
public struct ProviderLimitWindow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case session, weekly, monthly, other }
    public var id: String
    public var kind: Kind
    /// What the window is limited to when it is not the whole account: a model
    /// or a family of models.
    public var scope: String?
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(id: String, kind: Kind, scope: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.id = id; self.kind = kind; self.scope = scope
        self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0; self.resetsAt = resetsAt
    }
    public var leftPercent: Double { 100 - usedPercent }
}

/// Each proxy account retains its own allowance; percentages are never pooled.
public struct ProviderAccountLimits: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var plan: String?
    public var windows: [ProviderLimitWindow]
    public var checked: Date?
    public var message: String?
    public init(id: String, name: String, plan: String? = nil, windows: [ProviderLimitWindow] = [], checked: Date? = nil, message: String? = nil) {
        self.id = id; self.name = name; self.plan = plan; self.windows = windows; self.checked = checked; self.message = message
    }
}

public struct ProviderLimits: Sendable, Equatable, Identifiable {
    public var provider: NotesAIProvider
    public var name: String
    public var plan: String?
    public var windows: [ProviderLimitWindow] = []
    public var accounts: [ProviderAccountLimits] = []
    public var source: String?
    /// Why there are no windows.
    public var message: String?
    public var checked = Date()
    public var id: String { provider.rawValue }
    public init(provider: NotesAIProvider, name: String) { self.provider = provider; self.name = name }
}

/// Reads the account's limits the way T3 Code does: Claude Code and Codex
/// answer from their own CLI without a model request; Antigravity is asked
/// through its signed-in Google profile. Nothing is written or kept.
public enum ProviderLimitsProbe {
    static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue { return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil }
        guard let text = value as? String else { return nil }
        // Fractional seconds come with any number of digits.
        return ISO8601DateFormatter().date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
    private static func number(_ value: Any?) -> Double? {
        // JSON 0 and 1 also read as Bool; only a real boolean is rejected.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// The `get_usage` control response; percentages are already 0–100.
    static func claude(_ response: [String: Any]) -> (plan: String?, windows: [ProviderLimitWindow]) {
        guard response["rate_limits_available"] as? Bool == true, let limits = response["rate_limits"] as? [String: Any] else { return (response["subscription_type"] as? String, []) }
        var windows: [ProviderLimitWindow] = []
        for (id, kind) in [("five_hour", ProviderLimitWindow.Kind.session), ("seven_day", .weekly)] {
            guard let window = limits[id] as? [String: Any], let used = number(window["utilization"]) else { continue }
            windows.append(.init(id: id, kind: kind, usedPercent: used, resetsAt: date(window["resets_at"])))
        }
        for limit in limits["limits"] as? [[String: Any]] ?? [] where limit["kind"] as? String == "weekly_scoped" {
            guard let used = number(limit["percent"]), let name = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String else { continue }
            windows.append(.init(id: "seven_day_" + name.lowercased(), kind: .weekly, scope: name, usedPercent: used, resetsAt: date(limit["resets_at"])))
        }
        return (response["subscription_type"] as? String, windows)
    }

    /// `account/rateLimits/read`. `primary` and `secondary` are positions, not
    /// durations; without a duration, paid plans pair five hours with a week
    /// and Free/Go have one monthly allowance.
    static func codex(_ result: [String: Any]) -> (plan: String?, windows: [ProviderLimitWindow]) {
        guard let snapshot = (result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any] ?? result["rateLimits"] as? [String: Any] else { return (nil, []) }
        let plan = snapshot["planType"] as? String
        var windows: [ProviderLimitWindow] = []
        for (id, fallback) in [("primary", ["free", "go"].contains(plan ?? "") ? 43_200.0 : 300), ("secondary", 10_080)] {
            guard let window = snapshot[id] as? [String: Any], let used = number(window["usedPercent"]) else { continue }
            let minutes = number(window["windowDurationMins"]) ?? fallback
            windows.append(.init(id: id, kind: minutes <= 1_440 ? .session : minutes <= 10_080 ? .weekly : .monthly, usedPercent: used, resetsAt: date(window["resetsAt"])))
        }
        return (plan, windows)
    }

    private static func quota(_ id: String, kind: ProviderLimitWindow.Kind, scope: String?, _ quota: [String: Any]) -> ProviderLimitWindow? {
        guard let remaining = number(quota["remainingFraction"]) else { return nil }
        return .init(id: id, kind: kind, scope: scope, usedPercent: (1 - min(1, max(0, remaining))) * 100, resetsAt: date(quota["resetTime"]))
    }

    /// `retrieveUserQuotaSummary` names the shared buckets: Gemini, Claude and GPT
    /// together, and on Pro plans a separate weekly one for Gemini 4 Argon.
    static func antigravity(summary: [String: Any]) -> [ProviderLimitWindow] {
        var groups = (summary["groups"] as? [[String: Any]] ?? []).filter { !($0["buckets"] as? [Any] ?? []).isEmpty }
        if groups.isEmpty { groups = [["buckets": summary["buckets"] ?? []]] }
        var windows: [ProviderLimitWindow] = []
        for group in groups {
            // The short window first, as the other providers list theirs.
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).enumerated().sorted { ($0.element["window"] as? String == "5h" ? 0 : 1, $0.offset) < ($1.element["window"] as? String == "5h" ? 0 : 1, $1.offset) }.map(\.element)
            for bucket in buckets where bucket["disabled"] as? Bool != true {
                guard let id = bucket["bucketId"] as? String, !id.isEmpty, !windows.contains(where: { $0.id == id }) else { continue }
                // "Gemini Models" is the shared Gemini allowance; other Gemini groups such as
                // "Gemini 4 Argon" keep their own name, as their bucket ids also start with "gemini-".
                let name = (group["displayName"] as? String)?.trimmingCharacters(in: .whitespaces)
                let shared = name.map { $0.lowercased().hasSuffix("models") } ?? true
                let family = id.hasPrefix("3p-") ? "Claude & GPT" : id.hasPrefix("gemini-") && shared ? "Gemini" : name ?? id
                let kind: ProviderLimitWindow.Kind = bucket["window"] as? String == "weekly" ? .weekly : bucket["window"] as? String == "5h" ? .session : .other
                if let window = quota(id, kind: kind, scope: family, bucket) { windows.append(window) }
            }
        }
        return windows
    }

    /// Older accounts list a quota per model; the most used one stands for its family.
    static func antigravity(models: [String: Any]) -> [ProviderLimitWindow] {
        var windows: [String: ProviderLimitWindow] = [:]
        for (id, value) in models["models"] as? [String: [String: Any]] ?? [:] {
            let provider = value["modelProvider"] as? String
            let family = provider == "MODEL_PROVIDER_GOOGLE" || id.hasPrefix("gemini-") ? "Gemini" : provider == "MODEL_PROVIDER_ANTHROPIC" || id.hasPrefix("claude-") ? "Claude" : provider == "MODEL_PROVIDER_OPENAI" || id.hasPrefix("gpt-") ? "GPT" : nil
            guard let family else { continue }
            for (suffix, field, kind) in [("quota", "quotaInfo", ProviderLimitWindow.Kind.other), ("weekly", "weeklyQuotaInfo", .weekly)] {
                guard let info = value[field] as? [String: Any], let window = quota(family.lowercased() + "-" + suffix, kind: kind, scope: family, info) else { continue }
                if window.usedPercent > windows[window.id]?.usedPercent ?? -1 { windows[window.id] = window }
            }
        }
        return windows.values.sorted { $0.id < $1.id }
    }

    /// Never throws: a provider that cannot answer says why instead.
    public static func read(_ configuration: AIProviderConfiguration, store: LocalMediaStore) async -> ProviderLimits {
        var limits = ProviderLimits(provider: configuration.provider, name: configuration.name)
        if let endpoint = CLIProxyAccountLimits.endpoint(configuration) {
            do { return try await CLIProxyAccountLimits.read(configuration, endpoint: endpoint) }
            catch {
                limits.source = "CLIProxyAPI"
                limits.message = "No se pudieron leer los límites de CLIProxyAPI. Comprueba que su panel esté activo y revisa la URL en los ajustes del proveedor."
                return limits
            }
        }
        if CLIProxyAccountLimits.isProxy(configuration) {
            limits.source = "CLIProxyAPI"
            limits.message = "Configura la URL del panel de CLIProxyAPI en los ajustes avanzados del proveedor para consultar sus cuentas."
            return limits
        }
        do {
            switch configuration.provider {
            case .claudeCode: (limits.plan, limits.windows) = claude(try await ClaudeTextTransport(store: store, configuration: configuration).usage())
            case .codexCLI:
                let transport = CodexNotebookStreamingTransport(store: store, configuration: configuration)
                (limits.plan, limits.windows) = try await Task.detached { codex(try transport.rateLimits()) }.value
            case .antigravity: limits.windows = try await antigravityWindows(configuration)
            case .openCode: break
            }
            if limits.windows.isEmpty { limits.message = "Este proveedor no publica límites para esta cuenta." }
        } catch { limits.message = error.localizedDescription }
        limits.checked = Date()
        return limits
    }

    private static func json(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaError.invalid("Antigravity no devolvió sus límites.") }
        return object
    }

    /// Exchanges the profile's refresh token for an access token held only in
    /// memory, as the agent itself does, then asks for the quota.
    private static func antigravityWindows(_ configuration: AIProviderConfiguration) async throws -> [ProviderLimitWindow] {
        guard configuration.antigravityAuth.usesBrowserLogin else { throw MediaError.invalid("Los límites solo están disponibles con una cuenta de Google.") }
        let file = URL(fileURLWithPath: configuration.homePath).appendingPathComponent("antigravity-acp/acp_token.json")
        guard let data = try? Data(contentsOf: file), let token = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let client = token["client_id"] as? String, let secret = token["client_secret"] as? String, let refresh = token["refresh_token"] as? String else {
            throw MediaError.invalid("Inicia sesión en Antigravity con Google para ver sus límites.")
        }
        let configurationSession = URLSessionConfiguration.ephemeral
        configurationSession.timeoutIntervalForRequest = 10; configurationSession.httpShouldSetCookies = false
        let session = URLSession(configuration: configurationSession)
        defer { session.finishTasksAndInvalidate() }
        var form = URLComponents()
        form.queryItems = [.init(name: "client_id", value: client), .init(name: "client_secret", value: secret), .init(name: "refresh_token", value: refresh), .init(name: "grant_type", value: "refresh_token")]
        var exchange = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        exchange.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        guard let access = try await json(exchange, session: session)["access_token"] as? String, !access.isEmpty else { throw MediaError.invalid("Antigravity no renovó la sesión; vuelve a iniciar sesión en su cliente.") }
        let project = token["project_id"] as? String ?? ""
        func windows(_ operation: String, _ parse: ([String: Any]) -> [ProviderLimitWindow]) async -> [ProviderLimitWindow] {
            for endpoint in ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"] {
                var request = URLRequest(url: URL(string: endpoint + "/v1internal:" + operation)!)
                request.httpMethod = "POST"
                request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Named as the ACP agent Palladium runs. The quota service answers by client: under the
                // older "hub" name it lists only the Claude and GPT group, without Gemini or Gemini 4 Argon.
                request.setValue("antigravity/acp/1.0.0 (aidev_client; os_type=darwin; arch=arm64)", forHTTPHeaderField: "User-Agent")
                request.httpBody = try? JSONSerialization.data(withJSONObject: project.isEmpty ? [:] : ["project": project])
                if let found = (try? await json(request, session: session)).map(parse), !found.isEmpty { return found }
            }
            return []
        }
        let summary = await windows("retrieveUserQuotaSummary") { antigravity(summary: $0) }
        return summary.isEmpty ? await windows("fetchAvailableModels") { antigravity(models: $0) } : summary
    }
}

extension CodexNotebookStreamingTransport {
    /// Asks the app server for the account's limits; no thread is started.
    func rateLimits() throws -> [String: Any] {
        try configuration.validate()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else { throw MediaError.invalid("No se encuentra el ejecutable. Prepara el proveedor en Preferencias.") }
        let directory = try NotesProviderTransport(store: store).temporaryDirectory()
        let home = try Self.accountHome(configuration, in: directory)
        let connection = ProviderRPCConnection(configuration: configuration, directory: directory, environment: try NotesProviderTransport.codexEnvironment(configuration, home: home.path),
                                               arguments: ["app-server", "--listen", "stdio://", "--config", "cli_auth_credentials_store=\"file\"", "--config", "mcp_servers={}"])
        defer { connection.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { connection.cancel() }
        try connection.start()
        _ = try connection.request("initialize", params: ["clientInfo": ["name": "palladium", "title": "Palladium", "version": "0.3"], "capabilities": ["experimentalApi": true]])
        try connection.notify("initialized")
        return try connection.request("account/rateLimits/read", params: [:])
    }
}
