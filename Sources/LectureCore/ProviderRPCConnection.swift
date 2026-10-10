import Foundation
import Darwin

final class ProviderRPCConnection: @unchecked Sendable {
    let configuration: AIProviderConfiguration
    let directory: URL
    let environment: [String: String]
    let arguments: [String]
    let process = Process()
    private let input = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private var requestID = 0
    private var bytesRead = 0
    private let lock = NSLock()
    private let terminated = DispatchSemaphore(value: 0)
    private var started = false
    private var cancelled = false
    private var timer: DispatchSourceTimer?
    var sessionID: String?
    var output = ""
    var thought = ""
    var progress: (@Sendable (NotebookProviderProgress) -> Void)?
    var notificationHandler: ((String, [String: Any]) throws -> Void)?

    init(configuration: AIProviderConfiguration, directory: URL, environment: [String: String], arguments: [String] = []) {
        self.configuration = configuration; self.directory = directory; self.environment = environment
        self.arguments = arguments
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardInput = input; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [terminated] _ in terminated.signal() }
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        started = true
        let timeout = DispatchSource.makeTimerSource(queue: .global())
        timeout.schedule(deadline: .now() + ProviderRequestLimits.generation); timeout.setEventHandler { [weak self] in self?.cancel() }; timeout.resume()
        timer = timeout
    }

    func initialize() throws -> [String: Any] {
        let result = try request("initialize", params: ["protocolVersion": 2, "clientInfo": ["name": "notes-text-helper", "version": "1.0"], "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
        let info = result["agentInfo"] as? [String: Any]
        guard result["protocolVersion"] as? Int == 2, info?["name"] as? String == "antigravity-acp" else { throw MediaError.invalid("El ejecutable no identifica un servidor Antigravity ACP compatible.") }
        return result
    }

    func cancel() {
        lock.lock(); cancelled = true
        process.stopProviderHelper()
        lock.unlock()
        try? input.fileHandleForWriting.close()
    }

    func close() {
        timer?.cancel(); timer = nil
        cancel()
        if started { terminated.wait() }
        try? stdout.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func write(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func notify(_ method: String) throws { try write(["jsonrpc": "2.0", "method": method]) }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        requestID += 1
        let identifier = requestID
        try write(["jsonrpc": "2.0", "id": identifier, "method": method, "params": params])
        while true {
            let event = try readEvent()
            if let requestMethod = event["method"] as? String {
                if let serverID = event["id"] {
                    try write(["jsonrpc": "2.0", "id": serverID, "error": ["code": -32601, "message": "Tools, filesystem, terminal and user input are disabled."]])
                    throw MediaError.invalid("El proveedor solicitó herramientas o permisos; respuesta rechazada.")
                }
                if let notificationHandler { try notificationHandler(requestMethod, event["params"] as? [String: Any] ?? [:]) }
                else if requestMethod == "session/update", let params = event["params"] as? [String: Any] {
                    try acceptUpdate(params)
                }
                continue
            }
            guard event["id"] as? Int == identifier else { throw MediaError.invalid("Respuesta ACP fuera de orden.") }
            guard event["error"] == nil, let result = event["result"] as? [String: Any] else { throw MediaError.invalid("El proveedor rechazó la operación. Comprueba el login y el modelo en su cliente; no se cambia la nota.") }
            return result
        }
    }

    func readEvent() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw MediaError.invalid("Evento ACP inválido.") }
                return event
            }
            var storage = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(stdout.fileHandleForReading.fileDescriptor, &storage, storage.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw MediaError.invalid("Antigravity cerró la conexión o agotó el tiempo; reintenta explícitamente.") }
            let chunk = Data(storage.prefix(count))
            bytesRead += chunk.count
            guard bytesRead <= 2_000_000 else { throw MediaError.invalid("Salida ACP demasiado grande.") }
            buffer.append(chunk)
        }
    }

    private func acceptUpdate(_ params: [String: Any]) throws {
        guard let update = params["update"] as? [String: Any], let kind = update["sessionUpdate"] as? String else { throw MediaError.invalid("Actualización ACP inválida.") }
        if kind == "tool_call" || kind == "tool_call_update" {
            progress?(NotebookProviderProgress.blockedTool(id: update["toolCallId"] as? String, name: update["kind"] as? String))
            throw MediaError.invalid("Antigravity intentó usar herramientas; respuesta rechazada.")
        }
        guard params["sessionId"] as? String == sessionID,
              let content = update["content"] as? [String: Any], content["type"] as? String == "text", let text = content["text"] as? String else { return }
        if kind == "agent_thought_chunk" {
            thought = String((thought + text).prefix(12_000))
            progress?(.init(id: "acp-thought", title: "Pensando…", detail: thought, kind: .reasoning))
            return
        }
        guard kind == "agent_message_chunk" else { return }
        progress?(.init(id: "provider-response", title: "Redactando respuesta…"))
        guard output.utf8.count + text.utf8.count <= 60_000 else { throw MediaError.invalid("Respuesta Antigravity demasiado grande.") }
        output += text
    }
}
