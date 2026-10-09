import SwiftUI
import LectureCore

struct NotebookChatTurn: Identifiable, Equatable {
    let id: String
    let prompt: String
    var reply: String
    var messageIDs: [String]

    static func collect(_ messages: [NotebookMessage]) -> [NotebookChatTurn] {
        var turns: [NotebookChatTurn] = []
        for message in messages {
            if message.role == "user" || turns.isEmpty {
                turns.append(.init(id: message.id, prompt: message.text, reply: "", messageIDs: [message.id]))
            } else {
                let index = turns.count - 1
                turns[index].messageIDs.append(message.id)
                if message.role == "assistant" || message.role == "error" { turns[index].reply = message.text }
            }
        }
        return turns
    }
    static func visible(in frames: [String: CGRect], turns: [NotebookChatTurn], height: CGFloat) -> Set<String> {
        guard height > 0 else { return [] }
        let messages = Set(frames.filter { $0.value.maxY > 0 && $0.value.minY < height }.keys)
        return Set(turns.filter { $0.messageIDs.contains { messages.contains($0) } }.map(\.id))
    }

    static func active(in frames: [String: CGRect], turns: [NotebookChatTurn]) -> String? {
        guard let message = frames.filter({ $0.value.maxY > 24 }).min(by: { $0.value.minY < $1.value.minY })?.key else { return nil }
        return turns.first { $0.messageIDs.contains(message) }?.id
    }
}

struct NotebookChatMessageFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
private struct ChatNavigatorRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct NotebookChatNavigator: View {
    let turns: [NotebookChatTurn]
    let activeID: String?
    let visibleIDs: Set<String>
    var navigate: (String) -> Void
    @State private var hoveredID: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var tooltipHeight: CGFloat = 120
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.language") private var language = "es"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hoveredIndex: Int? { turns.firstIndex { $0.id == hoveredID } }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            Button { navigate(turn.id) } label: {
                                HStack {
                                    Spacer(minLength: 0)
                                    Capsule()
                                        .fill(hoveredID == turn.id ? NotebookAccent.color(accent) : visibleIDs.contains(turn.id) ? Color.primary : Color.secondary.opacity(0.4))
                                        .frame(width: MarkdownSectionEmphasis.width(index: index, hoveredIndex: hoveredIndex), height: 1.5)
                                }.frame(width: 32, height: 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .onHover { hoveredID = $0 ? turn.id : (hoveredID == turn.id ? nil : hoveredID) }
                                .background {
                                    GeometryReader { row in
                                        Color.clear.preference(key: ChatNavigatorRowFrames.self, value: [turn.id: row.frame(in: .named("chat-navigator"))])
                                    }
                                }
                                .accessibilityLabel((language == "en" ? "Jump to message: " : "Ir al mensaje: ") + turn.prompt)
                                .accessibilityAddTraits(visibleIDs.contains(turn.id) ? .isSelected : [])
                                .accessibilityIdentifier("notebook.chatJump." + turn.id)
                                .id(turn.id)
                        }
                    }.padding(.vertical, 8)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredID)
                }.scrollIndicators(.hidden)
                    .frame(height: min(geometry.size.height, CGFloat(turns.count) * 12 + 16))
                    .frame(maxHeight: .infinity)
                    .onChange(of: activeID) { _, id in if hoveredID == nil, let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .coordinateSpace(name: "chat-navigator")
        .onPreferenceChange(ChatNavigatorRowFrames.self) { rowFrames = $0 }
        .overlay {
            GeometryReader { geometry in
                if let turn = turns.first(where: { $0.id == hoveredID }), let row = rowFrames[turn.id] {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(turn.prompt.isEmpty ? (language == "en" ? "Attached files" : "Archivos adjuntos") : turn.prompt).font(.callout.weight(.medium)).lineLimit(2)
                        if !turn.reply.isEmpty { Text(turn.reply).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                    }.padding(12).frame(width: 260, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tooltipHeight = $0 }
                        .position(x: -140, y: MarkdownSectionTooltip.center(rowY: row.midY, height: tooltipHeight, availableHeight: geometry.size.height))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 32)
        .accessibilityIdentifier("notebook.chatNavigator")
        .onChange(of: turns.map(\.id)) { _, _ in hoveredID = nil }
    }
}
