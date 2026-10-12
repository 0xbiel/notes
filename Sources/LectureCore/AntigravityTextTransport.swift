import Foundation

public struct AntigravityTextTransport: Sendable {
    let store: LocalMediaStore
    let configuration: AIProviderConfiguration
    var secret: ProviderEnvironment.SecretReader = { try ProviderSecrets.read($0, $1) }

    /// `settings.json` for the ACP profile, as T3 Code writes it: the selected
    /// sign-in method and the Google Cloud target. Never holds a credential.
    static func profileSettings(_ configuration: AIProviderConfiguration) throws -> Data {
        var settings: [String: Any] = ["auth": ["type": configuration.antigravityAuth.rawValue]]
        var gcp: [String: String] = [:]
        if let project = configuration.gcpProject, !project.isEmpty { gcp["project"] = project }
        if let location = configuration.gcpLocation, !location.isEmpty { gcp["location"] = location }
        if !gcp.isEmpty { settings["gcp"] = gcp }
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        data.append(10)
        return data
    }

    /// Reports what a non-personal method still needs before it can sign in.
    func authIssue() throws -> String? {
        let project = configuration.gcpProject ?? "", location = configuration.gcpLocation ?? ""
        switch configuration.antigravityAuth {
        case .personal: return nil
        case .business: return project.isEmpty || location.isEmpty ? "Gemini Enterprise necesita un proyecto y una región de Google Cloud en Proveedores." : nil
        case .apiKey: return try apiKey() == nil ? "Introduce una clave de API de Gemini en Proveedores." : nil
        case .agentPlatform: return try apiKey() == nil && (project.isEmpty || location.isEmpty) ? "Agent Platform necesita una clave de API, o un proyecto y una región de Google Cloud, en Proveedores." : nil
        }
    }

    private func apiKey() throws -> String? {
        guard let key = try secret(.antigravity, ProviderSecrets.antigravityAPIKey), !key.isEmpty else { return nil }
        return key
    }

    /// The default Google-account sign-in leaves the profile untouched. Another
    /// method is recorded in the profile settings, which the agent reads.
    private func prepareAuth() throws {
        if let issue = try authIssue() { throw MediaError.invalid(issue) }
        let directory = URL(fileURLWithPath: configuration.homePath).appendingPathComponent("antigravity-acp")
        let file = directory.appendingPathComponent("settings.json")
        if configuration.antigravityAuth.usesBrowserLogin {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("acp_token.json").path) else { throw MediaError.invalid("Inicia sesión en Antigravity desde su cliente; Palladium no abre login ni copia credenciales.") }
        }
        let wanted = try Self.profileSettings(configuration)
        let current = try? Data(contentsOf: file)
        if configuration.antigravityAuth == .personal {
            guard let current, let object = try? JSONSerialization.jsonObject(with: current) as? [String: Any],
                  let auth = object["auth"] as? [String: Any], let type = auth["type"] as? String, type != AntigravityAuthMethod.personal.rawValue else { return }
        }
        guard current != wanted else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try wanted.write(to: file, options: .atomic)
    }

    public static func validateProfile(_ path: String) throws {
        let profile = URL(fileURLWithPath: path)
        for name in ["hooks.json", "mcp_config.json"] {
            let file = profile.appendingPathComponent("config/" + name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? 64_001 <= 64_000 else { throw MediaError.invalid("Perfil Antigravity con configuración no verificable.") }
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let entries = (object[name == "hooks.json" ? "hooks" : "mcpServers"] ?? object) as? [String: Any], entries.isEmpty else {
                throw MediaError.invalid("Antigravity tiene hooks o MCP globales. Usa un perfil independiente sin herramientas; Palladium no modifica tu perfil.")
            }
        }
    }

    private func connection() throws -> ProviderRPCConnection {
        try configuration.validate()
        try Self.validateProfile(configuration.homePath)
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath), FileManager.default.isExecutableFile(atPath: configuration.harnessPath) else { throw MediaError.invalid("Falta el servidor Antigravity ACP o localharness_external; la app de escritorio no sustituye ese transporte.") }
        let directory = try NotesProviderTransport(store: store).temporaryDirectory()
        var environment = ProcessInfo.processInfo.environment
        for name in Array(environment.keys) where name.hasPrefix("GEMINI_") || name.hasPrefix("GOOGLE_") || name.hasPrefix("AGY_") || name.hasPrefix("ANTIGRAVITY_") || name.hasPrefix("GCLOUD_") || name.hasPrefix("CLOUDSDK_") {
            environment.removeValue(forKey: name)
        }
        try ProviderEnvironment.apply(configuration, to: &environment, secret: secret)
        // Only the configured method's credential reaches the agent.
        for name in ["GEMINI_API_KEY", "GOOGLE_API_KEY"] { environment.removeValue(forKey: name) }
        if configuration.antigravityAuth == .apiKey, let key = try apiKey() { environment["GEMINI_API_KEY"] = key }
        if configuration.antigravityAuth == .agentPlatform, let key = try apiKey() { environment["GOOGLE_API_KEY"] = key }
        environment["GEMINI_HOME"] = configuration.homePath
        environment["AGY_ACP_FORCE_FILE_STORAGE"] = "1"
        environment["ANTIGRAVITY_HARNESS_PATH"] = configuration.harnessPath
        environment["BROWSER"] = "/usr/bin/true %s"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TMPDIR"] = directory.path
        return ProviderRPCConnection(configuration: configuration, directory: directory, environment: environment)
    }

    public func diagnose() async throws -> AIProviderDiagnostic {
        let connection = try connection()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                defer { connection.close() }
                try connection.start()
                let result = try connection.initialize()
                let info = result["agentInfo"] as? [String: Any] ?? [:]
                return AIProviderDiagnostic(message: "Antigravity ACP \(info["version"] as? String ?? "") · protocolo verificado · sin login ni envío")
            }.value
        } onCancel: { connection.cancel() }
    }

    public func send(_ batch: AIBatch, checked: @escaping @Sendable () async -> Void = {}) async throws -> AIBatch {
        let prompt = OpenRouterHarness.systemPrompt + "\n" + String(decoding: try OpenRouterHarness.payload(batch), as: UTF8.self)
        let text = try await generate(prompt, checked: checked)
        var result = batch
        result.decisions = try OpenRouterHarness.decodeResponse(text, for: batch)
        result.stage = .ready; result.error = nil; result.reportedCost = nil
        return result
    }

    func generate(_ prompt: String, images: [NotebookInputImage] = [], checked: @escaping @Sendable () async -> Void = {}, usage: @escaping @Sendable (ProviderTokenUsage) -> Void = { _ in }, progress: @escaping @Sendable (NotebookProviderProgress) async -> Void = { _ in }) async throws -> String {
        try configuration.validateSending()
        try prepareAuth()
        let method = configuration.antigravityAuth.rawValue
        let connection = try connection()
        return try await withTaskCancellationHandler {
            let prepared = try await Task.detached {
                do {
                    try connection.start()
                    let initialization = try connection.initialize()
                    if !images.isEmpty {
                        let capabilities = initialization["agentCapabilities"] as? [String: Any]
                        let promptCapabilities = capabilities?["promptCapabilities"] as? [String: Any]
                        guard promptCapabilities?["image"] as? Bool == true else { throw MediaError.invalid("This provider does not advertise image support. Choose an image-capable provider to send these attachments.") }
                    }
                    _ = try connection.request("authenticate", params: ["methodId": method])
                    let session = try connection.request("session/new", params: ["cwd": connection.directory.path, "mcpServers": []])
                    guard let sessionID = session["sessionId"] as? String, UUID(uuidString: sessionID) != nil else { throw MediaError.invalid("Sesión Antigravity inválida.") }
                    connection.sessionID = sessionID
                    _ = try connection.request("session/set_mode", params: ["sessionId": sessionID, "modeId": "default"])
                    if configuration.model != "default" {
                        _ = try connection.request("session/set_model", params: ["sessionId": sessionID, "modelId": configuration.model])
                    }
                    let current = (session["models"] as? [String: Any])?["currentModelId"] as? String
                    return (sessionID, configuration.model == "default" ? current ?? "default" : configuration.model)
                } catch { connection.close(); throw error }
            }.value
            await checked()
            let events = AsyncStream<NotebookProviderProgress>.makeStream()
            connection.progress = { events.continuation.yield($0) }
            await progress(.init(id: "provider-start", title: "Pensando…", kind: .reasoning))
            let worker = Task.detached {
                defer { connection.close(); events.continuation.finish() }
                var content: [[String: Any]] = [["type": "text", "text": prompt]]
                content += images.map { ["type": "image", "mimeType": "image/png", "data": $0.data.base64EncodedString()] }
                let finish = try connection.request("session/prompt", params: ["sessionId": prepared.0, "prompt": content])
                usage(Self.usage(finish, model: prepared.1, prompt: prompt, output: connection.output))
                guard finish["stopReason"] as? String == "end_turn" else { throw MediaError.invalid("Antigravity no completó el lote; no se aplica nada.") }
                return connection.output
            }
            for await event in events.stream { await progress(event) }
            return try await worker.value
        } onCancel: { connection.cancel() }
    }

    /// ACP reports token counts in the prompt result when the agent supports
    /// it; otherwise they are approximated from the text exchanged.
    static func usage(_ finish: [String: Any], model: String, prompt: String, output: String) -> ProviderTokenUsage {
        let count = ProviderTokenUsage.count
        guard let reported = finish["usage"] as? [String: Any], count(reported["inputTokens"]) + count(reported["outputTokens"]) > 0 else {
            return .approximate(model: model, prompt: prompt, output: output)
        }
        let cached = count(reported["cachedReadTokens"]), written = count(reported["cachedWriteTokens"])
        return .init(model: model, input: count(reported["inputTokens"]) - cached - written, cachedInput: cached, cacheWrite: written, output: count(reported["outputTokens"]) + count(reported["thoughtTokens"]))
    }

    public func models() async throws -> [AIProviderModel] {
        try prepareAuth()
        let method = configuration.antigravityAuth.rawValue
        let connection = try connection()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                defer { connection.close() }
                try connection.start(); _ = try connection.initialize()
                _ = try connection.request("authenticate", params: ["methodId": method])
                let session = try connection.request("session/new", params: ["cwd": connection.directory.path, "mcpServers": []])
                return try ProviderModelCatalog.antigravitySession(session)
            }.value
        } onCancel: { connection.cancel() }
    }
}
