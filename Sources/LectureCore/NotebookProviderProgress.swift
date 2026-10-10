import Foundation

/// Only provider-published reasoning and lifecycle events enter the work log.
/// Structured response JSON, headers and account metadata remain private to decoding.
public struct NotebookProviderProgress: Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String?
    public let kind: NotebookActivityKind
    public let failed: Bool
    public init(id: String, title: String, detail: String? = nil, kind: NotebookActivityKind = .status, failed: Bool = false) {
        self.id = id; self.title = title; self.detail = detail.map { String($0.prefix(12_000)) }
        self.kind = kind; self.failed = failed
    }
    static func decode(_ line: Data) -> Self? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        let part = event["part"] as? [String: Any] ?? [:]
        switch type {
        case "step_start", "turn.started": return .init(id: "provider-start", title: "Pensando…", kind: .reasoning)
        case "reasoning":
            return .init(id: "thought-" + (part["id"] as? String ?? "current"), title: "Pensando…", detail: part["text"] as? String, kind: .reasoning)
        case "text": return .init(id: "provider-response", title: "Redactando respuesta…")
        case "step_finish", "turn.completed": return .init(id: "provider-finished", title: "Comprobando respuesta…", detail: "Respuesta recibida. Comprobando el formato y los cambios propuestos.")
        case "tool_use":
            return blockedTool(id: part["id"] as? String, name: part["tool"] as? String)
        case "item.started", "item.updated", "item.completed":
            guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else { return nil }
            if kind == "reasoning" {
                return .init(id: "thought-" + (item["id"] as? String ?? "current"), title: "Pensando…", detail: item["text"] as? String, kind: .reasoning)
            }
            if kind == "agent_message" { return .init(id: "provider-response", title: "Redactando respuesta…") }
            if ["command_execution", "file_change", "mcp_tool_call", "web_search"].contains(kind) {
                return blockedTool(id: item["id"] as? String, name: kind)
            }
            return nil
        default: return nil
        }
    }
    static func blockedTool(id: String?, name: String?) -> Self {
        // Never surface raw commands, arguments, headers or tool output from a rejected session.
        let safeName = String((name ?? "tool").filter { $0.isLetter || $0.isNumber || "_-.".contains($0) }.prefix(80))
        return .init(id: "tool-" + (id ?? "current"), title: "Herramienta bloqueada · " + safeName, kind: .tool, failed: true)
    }
}

extension NotesProcess {
    func runStreaming(progress: @escaping @Sendable (NotebookProviderProgress) async -> Void) async throws -> Data {
        let events = AsyncStream<NotebookProviderProgress>.makeStream()
        let worker = Task.detached {
            defer { events.continuation.finish() }
            return try self.run { line in
                if let update = NotebookProviderProgress.decode(line) { events.continuation.yield(update) }
            }
        }
        return try await withTaskCancellationHandler {
            for await event in events.stream { await progress(event) }
            return try await worker.value
        } onCancel: { self.cancel() }
    }
}
