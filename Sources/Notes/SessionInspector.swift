import SwiftUI
import LectureCore

struct SessionInspector: View {
    @ObservedObject var model: Workbench
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.showInspector = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).modifier(ControlHoverBackground()).help("Cerrar inspector").accessibilityLabel("Cerrar inspector")
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 4) {
                inspectorTab("library", title: "Grabaciones", symbol: "waveform")
                inspectorTab("replay", title: "Transcripción", symbol: "text.bubble")
                inspectorTab("review", title: "Revisión", symbol: "checkmark.bubble")
                inspectorTab("changes", title: "Versiones", symbol: "clock.arrow.circlepath")
            }.padding(4).modifier(NotebookInputSurface(radius: 10))
                .padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            Group {
                switch model.selectedTab {
                case "library":
                    if let media = model.media { MediaInspector(media: media, model: model) }
                case "replay":
                    if let media = model.media, let job = media.selected, !job.syntheticFixture, job.notebookID == model.selectedNotebookID {
                        MediaTranscriptEditor(media: media, model: model, job: job).id(job.id)
                    } else {
                        InspectorEmptyState(title: "Sin transcripción", symbol: "text.bubble", detail: "Selecciona una grabación o importa audio para transcribirlo.")
                    }
                case "review":
                    if let ai = model.ai { AIReviewInspector(ai: ai, model: model) }
                default:
                    HistoryInspector(model: model, session: model.document)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.ultraThinMaterial)
            .accessibilityElement(children: .contain)
    }
    private func inspectorTab(_ id: String, title: String, symbol: String) -> some View {
        Button { model.selectedTab = id } label: {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(maxWidth: .infinity).frame(height: 28)
                .contentShape(Rectangle())
                .modifier(SelectorRowBackground(highlighted: model.selectedTab == id))
        }.buttonStyle(.plain).help(LocalizedStringKey(title))
            .accessibilityLabel(LocalizedStringKey(title))
            .accessibilityIdentifier("document.inspector." + id)
            .accessibilityAddTraits(model.selectedTab == id ? .isSelected : [])
    }
    private var title: String {
        switch model.selectedTab { case "library": "Grabaciones"; case "replay": "Transcripción"; case "review": "Revisión"; default: "Versiones" }
    }
}

struct HistoryInspector: View {
    @ObservedObject var model: Workbench
    let session: SessionDocument?
    private var sessionHistory: [FileChange] { session?.history ?? [] }
    @State private var selectedHistoryID: String?
    private var manual: Bool { model.inspectorHistoryMode == "editor" || session == nil }
    private var editorChange: EditorChange? { model.editor?.history.first { $0.id == selectedHistoryID } ?? model.editor?.history.last }
    private var sessionChange: FileChange? { sessionHistory.first { $0.id == selectedHistoryID } ?? sessionHistory.last }
    private var draft: Bool { manual && model.isDirty }
    private var before: String { draft ? model.bases[model.selectedNote ?? ""] ?? "" : manual ? editorChange?.before ?? "" : sessionChange?.before ?? "" }
    private var after: String { draft ? model.draftText : manual ? editorChange?.after ?? "" : sessionChange?.after ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AIOptionSelector(title: "Historial", symbol: "clock.arrow.circlepath",
                             options: (session != nil ? [AIOption(id: "session", title: "Sesión")] : []) + [AIOption(id: "editor", title: "Edición")],
                             selection: $model.inspectorHistoryMode)
                .onChange(of: model.inspectorHistoryMode) { _, _ in selectedHistoryID = nil }
            if draft {
                HStack { Label("Sin guardar", systemImage: "pencil").font(.callout).foregroundStyle(.orange); Spacer(); Button { model.saveDraft() } label: { Image(systemName: "square.and.arrow.down") }.help("Guardar copia") }
            } else if manual && !(model.editor?.history.isEmpty ?? true) {
                Picker("Versión de edición", selection: Binding(get: { selectedHistoryID ?? model.editor?.history.last?.id ?? "" }, set: { selectedHistoryID = $0 })) {
                    ForEach(Array((model.editor?.history ?? []).enumerated()), id: \.element.id) { index, change in Text("\(index + 1) · \(URL(fileURLWithPath: change.filename).deletingPathExtension().lastPathComponent)\(change.undone ? " · deshecha" : "")").tag(change.id) }
                }.labelsHidden()
            } else if !manual && !sessionHistory.isEmpty {
                Picker("Versión de sesión", selection: Binding(get: { selectedHistoryID ?? sessionHistory.last?.id ?? "" }, set: { selectedHistoryID = $0 })) {
                    ForEach(Array(sessionHistory.enumerated()), id: \.element.id) { index, change in Text("\(index + 1) · \(change.reason)\(change.undone ? " · deshecha" : "")").tag(change.id) }
                }.labelsHidden()
            }
            if before == after {
                InspectorEmptyState(title: "Sin cambios", symbol: "clock.arrow.circlepath", detail: "Las versiones guardadas aparecerán aquí.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(NoteDiff.lines(before: before, after: after).filter { !$0.text.hasPrefix("<!--") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.prefix).frame(width: 10)
                                Text(line.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(line.prefix == "+" ? Color.green : line.prefix == "−" ? Color.red : Color.secondary)
                                .padding(.vertical, 3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !draft {
                HStack {
                    Spacer()
                    Button {
                        if manual { model.undoEditor() }
                        else { model.perform { try model.engine?.undo() } }
                    } label: { Label("Deshacer último cambio", systemImage: "arrow.uturn.backward") }
                        .disabled(model.busy || model.isDirty || model.targetHasDraft || (manual ? model.editor?.history.contains(where: { !$0.undone }) != true : !sessionHistory.contains(where: { !$0.undone })))
                }
            }
        }.padding(12).onAppear { if session == nil { model.inspectorHistoryMode = "editor" } }
    }
}

struct InspectorEmptyState: View {
    let title: String
    let symbol: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium))
            Text(LocalizedStringKey(detail)).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InspectorTextField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 8)
            .modifier(NotebookInputSurface(radius: 8))
    }
}
