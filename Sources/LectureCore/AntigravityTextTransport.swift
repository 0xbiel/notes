import Foundation

public struct AntigravityTextTransport: Sendable {
    let store: LocalMediaStore
    let configuration: AIProviderConfiguration

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
                throw MediaError.invalid("Antigravity tiene hooks o MCP globales. Usa un perfil independiente sin herramientas; Notes no modifica tu perfil.")
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

    func generate(_ prompt: String, images: [NotebookInputImage] = [], checked: @escaping @Sendable () async -> Void = {}) async throws -> String {
        try configuration.validateSending()
        let token = URL(fileURLWithPath: configuration.homePath).appendingPathComponent("antigravity-acp/acp_token.json")
        guard FileManager.default.fileExists(atPath: token.path) else { throw MediaError.invalid("Inicia sesión en Antigravity desde su cliente; Notes no abre login ni copia credenciales.") }
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
                    _ = try connection.request("authenticate", params: ["methodId": "oauth-personal"])
                    let session = try connection.request("session/new", params: ["cwd": connection.directory.path, "mcpServers": []])
                    guard let sessionID = session["sessionId"] as? String, UUID(uuidString: sessionID) != nil else { throw MediaError.invalid("Sesión Antigravity inválida.") }
                    connection.sessionID = sessionID
                    _ = try connection.request("session/set_mode", params: ["sessionId": sessionID, "modeId": "default"])
                    if configuration.model != "default" {
                        _ = try connection.request("session/set_model", params: ["sessionId": sessionID, "modelId": configuration.model])
                    }
                    return sessionID
                } catch { connection.close(); throw error }
            }.value
            await checked()
            return try await Task.detached {
                defer { connection.close() }
                var content: [[String: Any]] = [["type": "text", "text": prompt]]
                content += images.map { ["type": "image", "mimeType": "image/png", "data": $0.data.base64EncodedString()] }
                let finish = try connection.request("session/prompt", params: ["sessionId": prepared, "prompt": content])
                guard finish["stopReason"] as? String == "end_turn" else { throw MediaError.invalid("Antigravity no completó el lote; no se aplica nada.") }
                return connection.output
            }.value
        } onCancel: { connection.cancel() }
    }

    public func models() async throws -> [AIProviderModel] {
        let token = URL(fileURLWithPath: configuration.homePath).appendingPathComponent("antigravity-acp/acp_token.json")
        guard FileManager.default.fileExists(atPath: token.path) else { throw MediaError.invalid("Inicia sesión en Antigravity para consultar los modelos de tu cuenta.") }
        let connection = try connection()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                defer { connection.close() }
                try connection.start(); _ = try connection.initialize()
                _ = try connection.request("authenticate", params: ["methodId": "oauth-personal"])
                let session = try connection.request("session/new", params: ["cwd": connection.directory.path, "mcpServers": []])
                return try ProviderModelCatalog.antigravitySession(session)
            }.value
        } onCancel: { connection.cancel() }
    }
}
