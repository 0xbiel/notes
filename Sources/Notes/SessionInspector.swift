import SwiftUI
import LectureCore

struct SessionInspector: View {
    @ObservedObject var model: Workbench
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { model.showInspector = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).modifier(ControlHoverBackground()).help("Cerrar inspector").accessibilityLabel("Cerrar inspector")
            }.padding(18)
            Picker("Inspector", selection: $model.selectedTab) {
                Label("Grabaciones", systemImage: "waveform").tag("library")
                Label("Transcripción", systemImage: "text.bubble").tag("replay")
                Label("Revisión", systemImage: "checkmark.bubble").tag("review")
                Label("Cambios", systemImage: "clock.arrow.circlepath").tag("changes")
            }.pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden().padding(.horizontal, 16).padding(.bottom, 16)
            Divider()
            if model.selectedTab == "library", let media = model.media {
                MediaInspector(media: media, model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = model.document {
                Group {
                    switch model.selectedTab {
                    case "library": if let media = model.media { MediaInspector(media: media, model: model) }
                    case "demo": RecordingInspector(model: model, session: session).id(session.id)
                    case "replay": if let media = model.media, let job = media.selected, job.notebookID == model.selectedNotebookID { MediaTranscriptEditor(media: media, model: model, job: job).id(job.id) } else { TranscriptInspector(model: model, session: session) }
                    case "review": if let ai = model.ai { AIReviewInspector(ai: ai, model: model) } else { ReviewInspector(model: model, session: session) }
                    default: HistoryInspector(model: model, session: session)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Sin sesiones", systemImage: "waveform", description: Text("Crea una sesión sintética desde el menú Demo."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var title: String {
        switch model.selectedTab { case "library": "Grabaciones"; case "replay": "Transcripción"; case "review": "Revisión"; default: "Versiones" }
    }
}

struct RecordingInspector: View {
    @ObservedObject var model: Workbench
    let session: SessionDocument
    @State private var grouping = "Fecha"
    @State private var search = ""
    private var groups: [(String, [SessionDocument])] {
        var result: [String: [SessionDocument]] = [:]
        for item in model.sessions where item.notebookID == model.selectedNotebookID {
            let tags = item.metadata.unitTags + item.metadata.examTags + item.topics.flatMap { $0.unitTags + $0.examTags }
            guard search.isEmpty || ([item.metadata.localDate, item.targetNote] + tags).joined(separator: " ").localizedCaseInsensitiveContains(search) else { continue }
            let keys: [String]
            if grouping == "Unidad" {
                let units = Array(Set(item.metadata.unitTags + item.topics.flatMap(\.unitTags))).sorted()
                keys = units.isEmpty ? ["Sin unidad"] : units
            } else if grouping == "Examen" {
                let exams = Array(Set(item.metadata.examTags + item.topics.flatMap(\.examTags))).sorted()
                keys = exams.isEmpty ? ["Sin examen"] : exams
            } else { keys = [item.metadata.localDate] }
            for key in keys { result[key, default: []].append(item) }
        }
        return result.keys.sorted(by: >).map { ($0, result[$0]!) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("Organizar grabaciones", selection: $grouping) {
                        ForEach(["Fecha", "Unidad", "Examen"], id: \.self) { Text($0) }
                    }.labelsHidden()
                    Spacer()
                    Button { model.perform { try model.createSession() } } label: { Image(systemName: "plus") }.disabled(model.busy).help("Nueva sesión sintética").accessibilityLabel("Nueva sesión sintética")
                }
                TextField("Buscar grabaciones", text: $search).textFieldStyle(.roundedBorder)
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(group.1) { item in
                            Button { model.select(item.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "waveform").foregroundStyle(item.id == session.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: item.targetNote).deletingPathExtension().lastPathComponent).font(.callout.weight(.medium)).lineLimit(2)
                                        Text("\(item.metadata.localTime) · \(timestamp(item.recording.duration)) · Sintético").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 2)
                                    if item.id == session.id { Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.accentColor) }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(item.id == session.id ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                    }
                }
                Divider()
                SessionTagEditor(model: model, session: session).id(session.id)
            }.padding(16)
        }
    }
}

struct SessionTagEditor: View {
    @ObservedObject var model: Workbench
    let session: SessionDocument
    @State private var subject: String
    @State private var units: String
    @State private var exams: String
    @State private var mode: InputMode
    @State private var topicUnits: [String]
    @State private var topicExams: [String]
    init(model: Workbench, session: SessionDocument) {
        self.model = model; self.session = session
        _subject = State(initialValue: session.metadata.subject)
        _units = State(initialValue: session.metadata.unitTags.joined(separator: ", "))
        _exams = State(initialValue: session.metadata.examTags.joined(separator: ", "))
        _mode = State(initialValue: session.metadata.inputMode)
        _topicUnits = State(initialValue: session.topics.map { $0.unitTags.joined(separator: ", ") })
        _topicExams = State(initialValue: session.topics.map { $0.examTags.joined(separator: ", ") })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.openNote(session.targetNote) } label: { Label("Abrir nota", systemImage: "doc.text") }.buttonStyle(.borderless)
            Text("Etiquetas").font(.headline)
            field("Unidad", text: $units)
            field("Examen", text: $exams)
            HStack(spacing: 6) {
                ForEach(session.metadata.suggestedUnits, id: \.self) { tag in Button(tag) { units = tag; save() }.font(.caption).buttonStyle(.bordered).help("Usar sugerencia de unidad") }
            }
            HStack(spacing: 6) {
                ForEach(session.metadata.suggestedExams, id: \.self) { tag in Button(tag) { exams = tag; save() }.font(.caption).buttonStyle(.bordered).help("Usar sugerencia de examen") }
            }
            Picker("Entrada", selection: $mode) { ForEach(InputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .onChange(of: mode) { _, _ in save() }
            Divider()
            Text("Secciones").font(.headline)
            ForEach(Array(session.topics.enumerated()), id: \.element.id) { index, topic in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top) {
                        Text("\(timestamp(topic.start))–\(timestamp(topic.end))").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(topic.title).font(.callout.weight(.medium))
                    }
                    TextField("Unidad de la sección", text: $topicUnits[index]).textFieldStyle(.roundedBorder).onChange(of: topicUnits[index]) { _, _ in save() }
                    TextField("Examen de la sección", text: $topicExams[index]).textFieldStyle(.roundedBorder).onChange(of: topicExams[index]) { _, _ in save() }
                }.padding(.vertical, 4)
            }
            DisclosureGroup("Detalles") {
                VStack(alignment: .leading, spacing: 12) {
                    field("Asignatura", text: $subject)
                    Text("\(session.metadata.localDate) · \(session.metadata.localTime)\n\(session.metadata.timezoneID)").font(.caption).foregroundStyle(.secondary)
                    Text(session.recording.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Silencio sintético. Las secciones comparten el mismo archivo.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.callout)
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).onChange(of: text.wrappedValue) { _, _ in save() }
        }
    }
    private func save() {
        model.perform {
            try model.engine?.updateMetadata(subject: subject, units: units, exams: exams, mode: mode,
                                            topicTags: zip(topicUnits, topicExams).map { (units: $0.0, exams: $0.1) })
        }
    }
}

struct TranscriptInspector: View {
    @ObservedObject var model: Workbench
    let session: SessionDocument
    @State private var manualText = ""
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Simulada").font(.caption.weight(.medium)).foregroundStyle(.orange)
                    Spacer()
                    Button { model.toggleDemo() } label: { Image(systemName: model.busy ? "stop.fill" : "play.fill") }.help(model.busy ? "Detener" : "Iniciar replay").accessibilityLabel(model.busy ? "Detener replay" : "Iniciar replay")
                    Button { model.nextStep() } label: { Image(systemName: "forward.end.fill") }.disabled(model.busy || session.replayCursor >= SyntheticFixtures.steps.count).help("Siguiente fragmento").accessibilityLabel("Siguiente fragmento")
                    Button { model.perform { try model.engine?.flush() } } label: { Image(systemName: "checkmark.circle") }
                        .disabled(model.busy || session.buffer.isEmpty || model.targetHasDraft).help("Aplicar lote pendiente").accessibilityLabel("Aplicar lote pendiente")
                }
                ProgressView(value: Double(session.replayCursor), total: Double(SyntheticFixtures.steps.count))
                HStack { Text("\(session.replayCursor) / \(SyntheticFixtures.steps.count)"); Spacer(); if !session.buffer.isEmpty { Text("\(session.buffer.count) en espera") } }.font(.caption).foregroundStyle(.secondary)
                if model.targetHasDraft { Label("Guarda la nota para aplicar el lote.", systemImage: "pencil").font(.caption).foregroundStyle(.orange) }
                Button { model.openNote(session.targetNote) } label: { Label(URL(fileURLWithPath: session.targetNote).deletingPathExtension().lastPathComponent, systemImage: "doc.text") }.font(.caption).buttonStyle(.borderless).lineLimit(1)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if session.transcript.isEmpty { ContentUnavailableView("Sin fragmentos", systemImage: "text.bubble", description: Text("Inicia la demo o avanza un fragmento.")) }
                    ForEach(session.transcript) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(timestamp(event.start)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if session.buffer.contains(where: { $0.id == event.id }) { Image(systemName: "clock").font(.caption).foregroundStyle(.orange) }
                            }
                            Text(event.text).font(.callout).textSelection(.enabled)
                        }
                    }
                    if !session.decisions.isEmpty {
                        DisclosureGroup("Decisiones") {
                            ForEach(Array(session.decisions.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4) }
                        }.font(.callout)
                    }
                    DisclosureGroup("Añadir texto") {
                        VStack(spacing: 10) {
                            TextEditor(text: $manualText).font(.callout).frame(height: 80).border(.separator)
                            HStack { Spacer(); Button("Revisar") {
                                model.perform {
                                    _ = try model.engine?.ingest(TranscriptEvent(id: "manual-\(UUID().uuidString)", start: 114, end: 120, text: manualText))
                                    if !model.targetHasDraft { try model.engine?.flush() }
                                    manualText = ""; model.selectedTab = "review"
                                }
                            }.disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy) }
                        }.padding(.top, 8)
                    }.font(.callout)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }
}

struct ReviewInspector: View {
    @ObservedObject var model: Workbench
    let session: SessionDocument
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.reviews.allSatisfy(\.resolved) {
                    ContentUnavailableView("Todo revisado", systemImage: "checkmark.circle", description: Text("Las dudas aparecerán aquí."))
                }
                if model.targetHasDraft { Label("Guarda la nota antes de aplicar cambios.", systemImage: "pencil").font(.caption).foregroundStyle(.orange) }
                ForEach(session.reviews.filter { !$0.resolved }) { review in
                    ReviewCard(model: model, review: review)
                }
                if session.reviews.contains(where: \.resolved) {
                    DisclosureGroup("Resueltas (\(session.reviews.filter(\.resolved).count))") {
                        ForEach(session.reviews.filter(\.resolved)) { review in Text(review.transcript).font(.caption).foregroundStyle(.secondary).padding(.vertical, 5) }
                    }.font(.callout)
                }
            }.padding(16)
        }
    }
}

struct ReviewCard: View {
    @ObservedObject var model: Workbench
    let review: ReviewItem
    @State private var replacement: String
    init(model: Workbench, review: ReviewItem) {
        self.model = model; self.review = review; _replacement = State(initialValue: review.suggestedText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(review.reason, systemImage: "questionmark.bubble").font(.callout.weight(.medium)).foregroundStyle(.orange)
            Text(review.transcript).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            TextEditor(text: $replacement).font(.callout).frame(height: 100).padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Texto confirmado para la revisión")
            HStack {
                Spacer()
                Button { model.perform { try model.engine?.resolveReview(review.id, replacement: nil) } } label: { Image(systemName: "xmark") }
                    .help("Mantener fuera de los apuntes").accessibilityLabel("Mantener fuera de los apuntes").disabled(model.busy || model.targetHasDraft)
                Button { model.perform { try model.engine?.resolveReview(review.id, replacement: replacement) } } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderedProminent).help("Aplicar texto confirmado").accessibilityLabel("Aplicar texto confirmado")
                    .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || model.targetHasDraft)
            }
            Divider()
        }
    }
}

struct HistoryInspector: View {
    @ObservedObject var model: Workbench
    let session: SessionDocument
    @State private var selectedHistoryID: String?
    private var manual: Bool { model.inspectorHistoryMode == "editor" }
    private var editorChange: EditorChange? { model.editor?.history.first { $0.id == selectedHistoryID } ?? model.editor?.history.last }
    private var sessionChange: FileChange? { session.history.first { $0.id == selectedHistoryID } ?? session.history.last }
    private var draft: Bool { manual && model.isDirty }
    private var before: String { draft ? model.bases[model.selectedNote ?? ""] ?? "" : manual ? editorChange?.before ?? "" : sessionChange?.before ?? "" }
    private var after: String { draft ? model.draftText : manual ? editorChange?.after ?? "" : sessionChange?.after ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Historial", selection: $model.inspectorHistoryMode) { Text("Sesión").tag("session"); Text("Edición").tag("editor") }
                .pickerStyle(.segmented).onChange(of: model.inspectorHistoryMode) { _, _ in selectedHistoryID = nil }
            if draft {
                HStack { Label("Sin guardar", systemImage: "pencil").font(.callout).foregroundStyle(.orange); Spacer(); Button { model.saveDraft() } label: { Image(systemName: "square.and.arrow.down") }.help("Guardar copia") }
            } else if manual && !(model.editor?.history.isEmpty ?? true) {
                Picker("Versión de edición", selection: Binding(get: { selectedHistoryID ?? model.editor?.history.last?.id ?? "" }, set: { selectedHistoryID = $0 })) {
                    ForEach(Array((model.editor?.history ?? []).enumerated()), id: \.element.id) { index, change in Text("\(index + 1) · \(URL(fileURLWithPath: change.filename).deletingPathExtension().lastPathComponent)\(change.undone ? " · deshecha" : "")").tag(change.id) }
                }.labelsHidden()
            } else if !manual && !session.history.isEmpty {
                Picker("Versión de sesión", selection: Binding(get: { selectedHistoryID ?? session.history.last?.id ?? "" }, set: { selectedHistoryID = $0 })) {
                    ForEach(Array(session.history.enumerated()), id: \.element.id) { index, change in Text("\(index + 1) · \(change.reason)\(change.undone ? " · deshecha" : "")").tag(change.id) }
                }.labelsHidden()
            }
            if before == after {
                ContentUnavailableView("Sin cambios", systemImage: "clock.arrow.circlepath", description: Text("Las versiones guardadas aparecerán aquí."))
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
                        .disabled(model.busy || model.isDirty || model.targetHasDraft || (manual ? model.editor?.history.contains(where: { !$0.undone }) != true : !session.history.contains(where: { !$0.undone })))
                }
            }
        }.padding(16)
    }
}
