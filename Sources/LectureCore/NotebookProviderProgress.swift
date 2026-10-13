import Foundation

/// Only provider-published reasoning and lifecycle events enter the work log.
/// Structured response JSON, headers and account metadata remain private to decoding.
public struct NotebookProviderProgress: Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String?
    public let kind: NotebookActivityKind
    public let failed: Bool
    /// Characters of the response written so far.
    public let written: Int?
    public init(id: String, title: String, detail: String? = nil, kind: NotebookActivityKind = .status, failed: Bool = false, written: Int? = nil) {
        self.id = id; self.title = title; self.detail = detail.map { String($0.prefix(12_000)) }
        self.kind = kind; self.failed = failed; self.written = written
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

/// Follows the structured response while the provider writes it, so the work
/// log can say which document is being written and show its latest lines.
/// The providers have no tools here: a long silence is the model writing a
/// whole document inside the JSON reply.
struct NotebookResponseStream {
    private var depth = 0
    private var inString = false, escaped = false, afterColon = false
    private var unicode = 0
    private var current = ""
    private var key = "", section = ""
    private var path: String?
    private var files = 0
    private var written = 0, reported = 0
    private var title = "Redactando respuesta…"

    /// Returns an update when a new part starts or enough text has arrived.
    mutating func accept(_ delta: String) -> NotebookProviderProgress? {
        var changed = false
        for character in delta {
            written += 1
            if inString {
                if unicode > 0 { unicode -= 1; continue }
                if escaped {
                    escaped = false
                    switch character { case "n": current.append("\n"); case "t": current.append("\t"); case "u": unicode = 4; case "r", "b", "f": break; default: current.append(character) }
                } else if character == "\\" { escaped = true }
                else if character == "\"" {
                    inString = false
                    if afterColon {
                        // The file an edit or output writes is named before its content.
                        if key == "path", depth == 3, ["edits", "outputs"].contains(section), !current.isEmpty {
                            path = current; files += 1; title = "Redactando · " + current.prefix(200); changed = true
                        }
                    } else {
                        key = String(current.prefix(80))
                        if depth == 1 { section = key; if key == "reply" { title = "Redactando respuesta…"; changed = changed || files > 0 } }
                    }
                    afterColon = false
                } else {
                    current.append(character)
                    if current.count > 4_000 { current.removeFirst(2_000) }
                }
                continue
            }
            switch character {
            case "\"": inString = true; current = ""
            case ":": afterColon = true
            case "{", "[": depth += 1; afterColon = false
            case "}", "]": depth -= 1; afterColon = false
            case ",": afterColon = false
            default: break
            }
        }
        guard changed || written - reported >= 240 else { return nil }
        reported = written
        // Only prose and document text are shown; keys and short fields are not.
        let writing = inString && afterColon && ["reply", "replacement", "source", "find"].contains(key)
        return .init(id: files == 0 ? "provider-response" : "provider-response-\(files)", title: title, detail: writing ? String(current.suffix(1_600)) : nil, written: written)
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
