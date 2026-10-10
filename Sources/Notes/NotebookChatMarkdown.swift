import SwiftUI
import AppKit
import LectureCore

/// A small native block renderer: inline Markdown remains selectable, code remains literal.
struct NotebookChatMarkdown: View {
    let text: String
    @AppStorage("notes.accent") private var accent = ""
    struct Block: Equatable {
        var kind: String
        var text: String
        var level = 0
    }
    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = [], paragraph: [String] = [], code: [String] = []
        let tables = MarkdownTables.blocks(in: text)
        let source = text as NSString
        let math = MarkdownMath.spans(in: text).filter { $0.display }.filter { span in
            let firstLine = source.lineRange(for: NSRange(location: span.range.location, length: 0))
            let prefix = source.substring(with: NSRange(location: firstLine.location, length: span.range.location - firstLine.location))
            let lastLine = source.lineRange(for: NSRange(location: NSMaxRange(span.range) - 1, length: 0))
            let suffix = source.substring(with: NSRange(location: NSMaxRange(span.range), length: NSMaxRange(lastLine) - NSMaxRange(span.range)))
            return prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var offset = 0, skipUntil = 0
        var fence: String?, language = ""
        func flush() { if !paragraph.isEmpty { result.append(.init(kind: "paragraph", text: paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            let start = offset; offset += line.utf16.count + 1
            if start < skipUntil { continue }
            if let span = math.first(where: { source.lineRange(for: NSRange(location: $0.range.location, length: 0)).location == start }) {
                flush(); result.append(.init(kind: "math", text: source.substring(with: span.range)))
                skipUntil = NSMaxRange(span.range); continue
            }
            if let table = tables.first(where: { $0.range.location == start }) {
                flush(); result.append(.init(kind: "table", text: (text as NSString).substring(with: table.range)))
                skipUntil = NSMaxRange(table.range); continue
            }
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
    @ViewBuilder private func inline(_ text: String, fontSize: CGFloat = 14, weight: NSFont.Weight = .regular) -> some View {
        if MarkdownMath.spans(in: text).isEmpty { Text(Self.inlineAttributed(text, accent: NotebookAccent.color(accent))) }
        else { MarkdownMathText(text: text, fontSize: fontSize, weight: weight, accent: NSColor(NotebookAccent.color(accent))) }
    }
    static func inlineAttributed(_ text: String, accent: Color) -> AttributedString {
        var result = InlineUnderline.attributed(text)
        for run in result.runs where run.link != nil { result[run.range].foregroundColor = accent }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.kind == "math" {
                    HStack { Spacer(minLength: 0); MarkdownMathText(text: block.text, fontSize: 17, accent: NSColor(NotebookAccent.color(accent))); Spacer(minLength: 0) }
                } else if block.kind == "table", let table = MarkdownTables.blocks(in: block.text).first?.table {
                    MarkdownTablePreview(table: table).frame(maxWidth: .infinity)
                } else if block.kind.hasPrefix("code:") {
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
                    inline(block.text, fontSize: block.level == 1 ? 22 : 17, weight: .semibold).font(.system(size: block.level == 1 ? 22 : 17, weight: .semibold)).padding(.top, 4)
                } else if block.kind == "quote" {
                    HStack(alignment: .top) { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 3); inline(block.text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                } else if ["task", "checked"].contains(block.kind) {
                    HStack(alignment: .top, spacing: 8) { Image(systemName: block.kind == "checked" ? "checkmark.square.fill" : "square").foregroundStyle(.secondary); inline(block.text).strikethrough(block.kind == "checked") }
                } else if block.kind.hasPrefix("list:") {
                    HStack(alignment: .top, spacing: 8) { Text(block.kind.count == 6 ? "•" : String(block.kind.dropFirst(5))).foregroundStyle(.secondary); inline(block.text) }
                } else { inline(block.text) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).tint(NotebookAccent.color(accent))
    }
}

struct NotebookWorkLog: View {
    @AppStorage("notes.language") private var language = "es"
    let activities: [NotebookActivity]
    var running = false
    var failed = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if !running { Image(systemName: failed ? "exclamationmark.circle" : "checkmark").frame(width: 18) }
                    Text(running ? (language == "en" ? "Working" : "Trabajando") : (language == "en" ? "Worked through \(activities.count) steps" : "\(activities.count) pasos realizados"))
                    if running, let start = activities.first?.date { Text(start, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }.foregroundStyle(.secondary).font(.callout).frame(minHeight: 24)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(expanded ? (language == "en" ? "Expanded" : "Expandido") : (language == "en" ? "Collapsed" : "Contraído"))
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(activities) { activity in
                        NotebookWorkLogEntry(activity: activity, active: running && activity.id == activities.last?.id, language: language)
                    }
                }.padding(.leading, 8)
            } else if running, let activity = activities.last {
                NotebookWorkLogEntry(activity: activity, active: true, language: language)
                    .id(activity.id)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("notebook.workLog")
    }
}

/// Each entry owns its disclosure so opening the work log never unfolds reasoning.
struct NotebookWorkLogEntry: View {
    let activity: NotebookActivity
    let active: Bool
    let language: String
    @State private var expanded = false
    @State private var hovered = false
    private var reasoning: Bool { activity.kind == .reasoning || activity.title.contains("Pensando") }
    private var detail: String { activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var preview: String {
        String(detail.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(240))
    }
    private var symbol: String? {
        if reasoning { return nil }
        if activity.failed == true { return "exclamationmark.circle" }
        if activity.title.contains("Leyendo") { return "doc.text.magnifyingglass" }
        if activity.title.contains("Conectando") { return "network" }
        if activity.title.contains("Redactando") { return "text.alignleft" }
        if activity.title.contains("Comprobando") || activity.title.contains("Validando") || activity.title.contains("comprobando") { return "checkmark.shield" }
        if activity.title.contains("Guardando") || activity.title.contains("Aplicando") || activity.title.contains("Corrigiendo") { return "pencil.line" }
        if activity.kind == .tool { return "wrench.and.screwdriver" }
        return "doc.text"
    }
    @ViewBuilder private var label: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).frame(width: 18) }
            Text(reasoning ? (language == "en" ? (active ? "Thinking…" : "Thought") : (active ? "Pensando…" : "Razonamiento")) : NotebookAssistantText.display(activity.title, language: language))
                .lineLimit(1)
            if reasoning && !expanded && !preview.isEmpty {
                Text(preview).lineLimit(1).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if active { Text(language == "en" ? "Now" : "Ahora").font(.caption2).foregroundStyle(.tertiary) }
            if !detail.isEmpty { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)) }
        }.font(.system(size: 13)).foregroundStyle(activity.failed == true ? Color.red : Color.secondary)
            .frame(minHeight: 24).padding(.horizontal, 4).contentShape(Rectangle())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail.isEmpty { label }
            else {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: { label }
                    .buttonStyle(.plain)
                    .background(hovered ? Color.primary.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .onHover { hovered = $0 }
                    .accessibilityLabel(reasoning ? (language == "en" ? "Thinking details" : "Detalles del razonamiento") : NotebookAssistantText.display(activity.title, language: language))
                    .accessibilityValue(expanded ? (language == "en" ? "Expanded" : "Expandido") : (language == "en" ? "Collapsed" : "Contraído"))
                    .accessibilityIdentifier("notebook.workLog.entry." + activity.id)
            }
            if expanded && !detail.isEmpty {
                ScrollView {
                    if reasoning { NotebookChatMarkdown(text: detail).font(.callout) }
                    else { Text(NotebookAssistantText.display(detail, language: language)).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }.frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8).padding(.leading, reasoning ? 4 : 28).padding(.trailing, 8)
                    .accessibilityIdentifier("notebook.workLog.detail." + activity.id)
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
