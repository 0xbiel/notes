import SwiftUI
import LectureCore
import AppKit

struct MediaInspector: View {
    @ObservedObject var media: MediaController
    @ObservedObject var model: Workbench
    @State private var filter = ""
    @State private var hoveredID: String?
    @State private var grouping = "Fecha"
    private var filtered: [MediaJob] { media.jobs.filter { !$0.syntheticFixture && $0.notebookID == model.selectedNotebookID && (filter.isEmpty || ([$0.sourceName, $0.targetNote] + $0.unitTags + $0.examTags).joined(separator: " ").localizedCaseInsensitiveContains(filter)) } }
    private var groups: [(String, [MediaJob])] {
        var result: [String: [MediaJob]] = [:]
        for job in filtered {
            let keys = grouping == "Unidad" ? (job.unitTags.isEmpty ? ["Sin unidad"] : job.unitTags) : grouping == "Examen" ? (job.examTags.isEmpty ? ["Sin examen"] : job.examTags) : [job.classDate.formatted(date: .numeric, time: .omitted)]
            for key in keys { result[key, default: []].append(job) }
        }
        return result.keys.sorted(by: >).map { ($0, result[$0]!) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    AIOptionSelector(title: "Agrupar grabaciones", symbol: "line.3.horizontal.decrease", options: [AIOption(id: "Fecha", title: "Fecha"), AIOption(id: "Unidad", title: "Unidad"), AIOption(id: "Examen", title: "Examen")], selection: $grouping)
                    Spacer()
                    Button { model.importMedia() } label: { Image(systemName: "square.and.arrow.down").frame(width: 28, height: 28) }.buttonStyle(.plain).modifier(ControlHoverBackground()).accessibilityLabel("Importar audio o MP4").help("Importar audio o MP4").disabled(media.busy || media.isRecording)
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar grabaciones", text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Borrar búsqueda")
                    }
                }.padding(9).modifier(NotebookInputSurface(radius: 8))
                ForEach(groups, id: \.0) { group in
                    Group {
                        if group.0 == "Sin unidad" || group.0 == "Sin examen" { Text(LocalizedStringKey(group.0)) }
                        else { Text(group.0) }
                    }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(group.1) { job in
                        Button { media.select(job.id) } label: {
                            HStack {
                                Image(systemName: job.isMicrophone ? "mic" : "waveform").foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) { Text(job.sourceName).lineLimit(1); (Text(timestamp(job.duration) + " · ") + Text(LocalizedStringKey(job.stage.label))).font(.caption).foregroundStyle(.secondary) }
                                Spacer(); if job.id == media.selectedID { Image(systemName: "checkmark") }
                            }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .modifier(SelectorRowBackground(highlighted: job.id == media.selectedID || hoveredID == job.id))
                        }.buttonStyle(.plain).disabled(media.isRecording)
                            .onHover { hoveredID = $0 ? job.id : nil }
                            .accessibilityAddTraits(job.id == media.selectedID ? .isSelected : [])
                    }
                }
                if let job = media.selected, !job.syntheticFixture, job.notebookID == model.selectedNotebookID {
                    Divider()
                    MediaDetail(media: media, job: job).id(job.id)
                        .padding(12).modifier(NotebookInputSurface(radius: 12))
                } else if filtered.isEmpty { InspectorEmptyState(title: filter.isEmpty ? "Sin grabaciones" : "Sin resultados", symbol: "waveform", detail: filter.isEmpty ? "Importa audio/MP4 o pulsa Grabar. El audio se guarda en este Mac." : "Prueba con otro nombre, unidad o examen.").frame(minHeight: 180) }
                if let error = media.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(12)
        }
    }
}

struct MediaDetail: View {
    @ObservedObject var media: MediaController
    let job: MediaJob
    @State private var date: Date
    @State private var units: String
    @State private var exams: String
    @State private var mode: InputMode
    init(media: MediaController, job: MediaJob) {
        self.media = media; self.job = job; _date = State(initialValue: job.classDate)
        _units = State(initialValue: job.unitTags.joined(separator: ", ")); _exams = State(initialValue: job.examTags.joined(separator: ", ")); _mode = State(initialValue: job.inputMode ?? .lecture)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(job.stage.label)).font(.headline)
            if media.busy { ProgressView(value: job.progress); Button("Cancelar") { media.cancel() } }
            if media.isRecording { Text("\(timestamp(job.duration)) · Micrófono activo").foregroundStyle(.red) }
            if let live = job.live {
                Text("\(live.processedChunks) de \(live.sealedChunks) fragmentos transcritos · \(live.backlog) pendientes").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("Whisper local transcribe mientras grabas; al detener termina los fragmentos pendientes.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Entrada", selection: $mode) { ForEach(InputMode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }.onChange(of: mode) { _, _ in save() }.disabled(media.busy || media.isRecording)
            DatePicker("Fecha de clase", selection: $date, displayedComponents: [.date]).onChange(of: date) { _, _ in save() }.disabled(media.busy || media.isRecording)
            TextField("Unidad (separada por comas)", text: $units).modifier(InspectorTextField()).onChange(of: units) { _, _ in save() }.disabled(media.busy || media.isRecording)
            TextField("Examen", text: $exams).modifier(InspectorTextField()).onChange(of: exams) { _, _ in save() }.disabled(media.busy || media.isRecording)
            if job.audioRelativePath != nil {
                HStack { Button { media.playPause() } label: { Image(systemName: media.playing ? "pause.fill" : "play.fill") }; Text("\(timestamp(media.position)) / \(timestamp(job.duration))").font(.caption.monospaced()) }
                Slider(value: Binding(get: { min(media.position, max(job.duration, 1)) }, set: { media.seek($0) }), in: 0...max(job.duration, 1)).disabled(media.isRecording)
                Button(LocalizedStringKey(job.completedChunks > 0 && job.stage != .transcribed ? "Reanudar transcripción" : "Transcribir en español")) { media.transcribe() }
                    .disabled(media.busy || media.isRecording || !media.whisperAvailable || job.stage == .transcribed)
                if let configuration = media.whisperConfiguration(for: job) {
                    Text("\(configuration.model.displayName) · local · \(job.live == nil ? "audio importado" : "grabación en directo")").font(.caption).foregroundStyle(.secondary)
                }
                Text("En Transcripción puedes enviar fragmentos al proveedor elegido en Preferencias y revisar sus propuestas antes de aplicarlas.").font(.caption).foregroundStyle(.secondary)
            }
            if [.interrupted, .failed, .cancelled].contains(job.stage), job.sourceCopyComplete { Button("Reanudar preparación") { media.resume() }.disabled(media.busy || media.isRecording) }
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if job.duplicateOf != nil { Text("Audio idéntico a otra importación; se reutiliza su preparación.").font(.caption).foregroundStyle(.secondary) }
            if !job.transcript.isEmpty {
                Divider(); Text("Transcripción").font(.headline)
                Text("Verifica nombres, cifras y negaciones antes de enviar a IA.").font(.caption).foregroundStyle(.secondary)
                ForEach(job.transcript) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(timestamp(segment.start)) { media.seek(segment.start) }.font(.caption.monospaced()).buttonStyle(.borderless)
                        Text(segment.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            DisclosureGroup("Detalles") {
                Text("Importado: \(job.importedAt.formatted())\n\(job.timezoneID)\n\(job.targetNote)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func save() { media.tags(date: date, units: units, exams: exams, mode: mode) }
}

struct MediaTranscriptEditor: View {
    @ObservedObject var media: MediaController
    @ObservedObject var model: Workbench
    let job: MediaJob
    @State private var selected: Set<String> = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(job.sourceName).font(.headline)
                Text(LocalizedStringKey(job.syntheticFixture ? "Texto inventado para probar la IA. No procede de Whisper ni del micrófono." : "Escucha y corrige nombres, cifras o negaciones. Se conserva la salida original de Whisper en la grabación local.")).font(.caption).foregroundStyle(.secondary)
                if job.completedChunks > 1 { Text(LocalizedStringKey(job.live == nil ? "Revisa las uniones de los fragmentos de cinco minutos y las negaciones." : "Revisa las uniones de los fragmentos de 30 segundos y las negaciones.")).font(.caption).foregroundStyle(.orange) }
                if let warning = job.asrQualityWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if job.transcript.isEmpty { Text("Transcribe esta grabación desde Grabaciones.").foregroundStyle(.secondary) }
                if let ai = model.ai { AISendControls(ai: ai, job: job, selected: $selected) }
                ForEach(job.transcript) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle("Seleccionar", isOn: Binding(get: { selected.contains(segment.id) }, set: { if $0 { selected.insert(segment.id) } else { selected.remove(segment.id) } })).labelsHidden().modifier(NotebookToggleAccent())
                            Button(timestamp(segment.start)) { media.seek(segment.start) }.font(.caption.monospaced()).buttonStyle(.borderless)
                        }
                        if segment.boundaryReview == true { Text("Unión de audio · revisa negaciones y correcciones").font(.caption2).foregroundStyle(.orange) }
                        TextEditor(text: Binding(get: { media.selected?.transcript.first { $0.id == segment.id }?.text ?? segment.text }, set: { media.editSegment(segment.id, text: $0) }))
                            .font(.callout).scrollContentBackground(.hidden).padding(6).frame(minHeight: 60, maxHeight: 130).modifier(NotebookInputSurface(radius: 8)).disabled(job.syntheticFixture || media.busy || media.isRecording)
                    }
                }
            }.padding(12)
        }
    }
}
