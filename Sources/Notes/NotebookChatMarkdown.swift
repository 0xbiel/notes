import SwiftUI
import AppKit
import LectureCore

/// A small native block renderer: inline Markdown remains selectable, code remains literal.
struct NotebookChatMarkdown: View {
    let text: String
    struct Block: Equatable {
        var kind: String
        var text: String
        var level = 0
    }
    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = [], paragraph: [String] = [], code: [String] = []
        var fence: String?, language = ""
        func flush() { if !paragraph.isEmpty { result.append(.init(kind: "paragraph", text: paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.hasPrefix(active) { result.append(.init(kind: "code:" + language, text: code.joined(separator: "\n"))); code = []; fence = nil }
                else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix(3)); language = String(trimmed.dropFirst(3)); continue
            }
            if trimmed.isEmpty { flush(); continue }
            let headings = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(headings), trimmed.dropFirst(headings).first == " " {
                flush(); result.append(.init(kind: "heading", text: String(trimmed.dropFirst(headings + 1)), level: headings)); continue
            }
            if trimmed.hasPrefix(">") { flush(); result.append(.init(kind: "quote", text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if let range = trimmed.range(of: #"^[-+*]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
                flush(); result.append(.init(kind: trimmed[range].lowercased().contains("[x]") ? "checked" : "task", text: String(trimmed[range.upperBound...]))); continue
            }
            if let range = trimmed.range(of: #"^(?:[-+*]|\d+[.)])\s+"#, options: .regularExpression) {
                flush(); result.append(.init(kind: "list:" + String(trimmed[range]).trimmingCharacters(in: .whitespaces), text: String(trimmed[range.upperBound...]))); continue
            }
            paragraph.append(line)
        }
        flush()
        if fence != nil { result.append(.init(kind: "code:" + language, text: code.joined(separator: "\n"))) }
        return result
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.kind.hasPrefix("code:") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(block.kind.dropFirst(5))).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.plain).accessibilityLabel("Copiar código")
                        }
                        ScrollView(.horizontal) { Text(block.text).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: false).textSelection(.enabled) }
                    }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                } else if block.kind == "heading" {
                    inline(block.text).font(.system(size: block.level == 1 ? 22 : 17, weight: .semibold)).padding(.top, 4)
                } else if block.kind == "quote" {
                    HStack(alignment: .top) { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 3); inline(block.text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                } else if ["task", "checked"].contains(block.kind) {
                    HStack(alignment: .top, spacing: 8) { Image(systemName: block.kind == "checked" ? "checkmark.square.fill" : "square").foregroundStyle(.secondary); inline(block.text).strikethrough(block.kind == "checked") }
                } else if block.kind.hasPrefix("list:") {
                    HStack(alignment: .top, spacing: 8) { Text(block.kind.count == 6 ? "•" : String(block.kind.dropFirst(5))).foregroundStyle(.secondary); inline(block.text) }
                } else { inline(block.text) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}

struct NotebookWorkLog: View {
    @AppStorage("notes.language") private var language = "es"
    let activities: [NotebookActivity]
    var running = false
    var failed = false
    @State private var expanded = false
    private func symbol(_ title: String) -> String {
        if title.contains("Leyendo") { return "doc.text.magnifyingglass" }
        if title.contains("BOE") || title.contains("artículo") { return "globe" }
        if title.contains("Guardando") || title.contains("Aplicando") { return "pencil.line" }
        return "sparkles"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.mini).frame(width: 18) }
                    else { Image(systemName: failed ? "exclamationmark.circle" : "checkmark").frame(width: 18) }
                    Text(running ? (language == "en" ? "Working" : "Trabajando") : (language == "en" ? "Worked through \(activities.count) steps" : "\(activities.count) pasos realizados"))
                    if running, let start = activities.first?.date { Text(start, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }.foregroundStyle(.secondary).font(.callout)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if running && !expanded {
                Text(NotebookAssistantText.display(activities.last?.title ?? "Preparando cambios…", language: language))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(activities) { activity in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: symbol(activity.title)).frame(width: 18)
                            Text(NotebookAssistantText.display(activity.title, language: language)).frame(maxWidth: .infinity, alignment: .leading)
                            if running && activity.id == activities.last?.id {
                                Text(language == "en" ? "Now" : "Ahora").foregroundStyle(.tertiary)
                            } else { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                    }
                }.padding(.leading, 12).padding(.leading, 14)
                    .overlay(alignment: .leading) { Rectangle().fill(.separator.opacity(0.5)).frame(width: 1).padding(.leading, 8) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NotebookChangedFiles: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    let message: NotebookMessage
    @State private var expanded: Set<String> = []
    private func lines(_ path: String) -> [DiffLine] {
        let timeline = assistant.store.timeline(model.currentNotebook.id)
        guard let index = timeline.firstIndex(where: { $0.id == message.checkpointID }) else { return [] }
        let before = index > 0 ? timeline[index - 1].files[path].flatMap { try? assistant.store.content($0) } ?? "" : ""
        let after = timeline[index].files[path].flatMap { try? assistant.store.content($0) } ?? ""
        return NoteDiff.lines(before: before, after: after).filter { $0.prefix != " " }
    }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(message.files, id: \.self) { path in
                let diff = lines(path)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { model.openNote(path) } label: { Label(path, systemImage: "doc.text").lineLimit(1) }
                            .buttonStyle(.plain).disabled(!model.notes.contains(path))
                        Spacer(minLength: 4)
                        Text("+\(diff.filter { $0.prefix == "+" }.count)").foregroundStyle(.green)
                        Text("−\(diff.filter { $0.prefix == "−" }.count)").foregroundStyle(.red)
                        Button { if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) } } label: { Image(systemName: expanded.contains(path) ? "chevron.up" : "chevron.down") }
                            .buttonStyle(.plain).accessibilityLabel("Ver cambios: \(path)")
                    }.font(.callout)
                    if expanded.contains(path) {
                        ScrollView([.horizontal, .vertical]) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(diff) { line in Text(line.prefix + " " + line.text).foregroundStyle(line.prefix == "+" ? Color.green : Color.red) }
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxHeight: 180)
                    }
                }.padding(12)
            }
        }.background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
    }
}
