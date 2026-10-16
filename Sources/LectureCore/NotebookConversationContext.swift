import Foundation

/// Provider context is a bounded projection, never a mutation of the saved conversation.
/// Like T3's history handoff, retain intact turns and allow omitted material to be read.
public enum NotebookConversationContext {
    public static let historyPath = "@conversation"
    public static let byteBudget = 32_000
    public static let compactByteBudget = 8_000

    public enum Command: Equatable { case compact, context, usage }
    public static func command(_ text: String, hasAttachments: Bool = false) -> Command? {
        guard !hasAttachments else { return nil }
        let parts = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first, first == "/compact" || first == "/context" else { return nil }
        guard parts.count == 1 else { return .usage }
        return first == "/compact" ? .compact : .context
    }

    public static func effectiveBudget(_ budget: Int?) -> Int {
        max(compactByteBudget, min(byteBudget, budget ?? byteBudget))
    }

    public static func encodedBytes(_ messages: [NotebookMessage], indices: [Int]) throws -> Int {
        try JSONEncoder().encode(indices.map { Message(messages[$0]) }).count
    }

    public struct Message: Encodable {
        public let id: String
        public let role: String
        public let text: String
        public let files: [String]
        public let attachments: [NotebookAttachment]?
        public let appGenerated: Bool?
        init(_ message: NotebookMessage) {
            id = message.id; role = message.role; text = message.text
            files = message.files; attachments = message.attachments; appGenerated = message.appGenerated
        }
    }

    public static func selectedIndices(_ messages: [NotebookMessage], budget: Int = byteBudget) throws -> [Int] {
        let encoder = JSONEncoder()
        let costs = try messages.map { try encoder.encode(Message($0)).count + 1 }
        var selected = Set<Int>(), remaining = budget - 2
        func add(_ index: Int?, required: Bool = false) {
            guard let index, messages[index].contextCommand != true, !selected.contains(index) else { return }
            guard required || costs[index] <= remaining else { return }
            selected.insert(index); remaining -= costs[index]
        }
        // Never silently truncate the current user request, even if it alone exceeds the budget.
        add(messages.lastIndex(where: { $0.role == "user" && $0.appGenerated != true && $0.contextCommand != true }), required: true)
        add(messages.lastIndex(where: { $0.role == "user" && $0.contextCommand != true }), required: true)
        add(messages.lastIndex(where: { $0.role == "assistant" && $0.contextCommand != true }))
        add(messages.firstIndex(where: { $0.role == "user" && $0.contextCommand != true }))
        for index in messages.indices.reversed() { add(index) }
        return selected.sorted()
    }

    /// Each page is one intact message or a marked text fragment, with a continuation cursor.
    /// Offsets count Swift Characters so Unicode is never split in the middle of a character.
    public static func read(_ path: String, messages: [NotebookMessage]) throws -> String {
        let parts = path.components(separatedBy: "#")
        guard parts.first == historyPath, parts.count <= 2 else { throw MediaError.invalid("Invalid conversation history path.") }
        let cursor = parts.count == 1 ? ["0", "0"] : parts[1].components(separatedBy: ":")
        guard cursor.count == 2, let index = Int(cursor[0]), let offset = Int(cursor[1]),
              messages.indices.contains(index), offset >= 0 else {
            throw MediaError.invalid("Invalid conversation history cursor.")
        }
        let message = messages[index]
        let source = message.text + (message.attachments ?? []).map { "\n[Attachment \($0.id): \($0.name)]\n\($0.text)" }.joined()
        guard offset <= source.count else { throw MediaError.invalid("Invalid conversation history cursor.") }
        let fragment = String(source.dropFirst(offset).prefix(4_000))
        let end = offset + fragment.count
        let next = end < source.count ? "\(historyPath)#\(index):\(end)"
            : index + 1 < messages.count ? "\(historyPath)#\(index + 1):0" : "End of conversation"
        struct Page: Encodable {
            let index: Int, id: String, role: String, text: String, files: [String], next: String
        }
        return String(decoding: try JSONEncoder().encode(Page(index: index, id: message.id, role: message.role,
            text: fragment, files: message.files, next: next)), as: UTF8.self)
    }
}
