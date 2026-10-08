import SwiftUI
import LectureCore

struct AISendControls: View {
    @ObservedObject var ai: AIController
    let job: MediaJob
    @Binding var selected: Set<String>
    @State private var showPayload = false
    private var segments: [MediaTranscriptSegment] { job.transcript.filter { selected.contains($0.id) } }
    private var context: String { AIOutbox.relevantContext(note: (try? ai.outbox.workspace.readNote(job.targetNote)) ?? "", selected: segments) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ai.providerSettings.selectedProvider == .openCode ? (job.syntheticFixture ? "Demo inventada · retención permitida" : "OpenRouter gratuito · ZDR exigido") : ai.providerSettings.selectedProvider.title).font(.subheadline.weight(.semibold))
            Text(ai.providerSettings.selectedProvider == .openCode ? (job.syntheticFixture ? "Solo envía los cuatro fragmentos y su nota inventada exacta. Permite retención del proveedor; prohíbe entrenamiento. No incluye apuntes reales." : "Envía el texto seleccionado y hasta 2.000 caracteres relevantes de la copia. El audio permanece local. Los cambios siguen el permiso elegido en General.") : "Envía los fragmentos y contexto limitado mediante tu cuenta. Se aplican sus costes y condiciones de retención. El audio permanece local; los cambios siguen el permiso elegido en General.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(selected.count == job.transcript.count ? "Quitar selección" : "Seleccionar todos") { selected = selected.count == job.transcript.count ? [] : Set(job.transcript.map(\.id)) }.disabled(job.transcript.isEmpty)
                Spacer()
                Button("Ver envío") { showPayload.toggle() }.disabled(segments.isEmpty)
                Button(job.syntheticFixture ? "Enviar demo" : "Enviar selección") { ai.send(media: job, ids: selected) }.buttonStyle(.borderedProminent).disabled(segments.isEmpty || job.stage == .transcribing || (job.syntheticFixture && segments.count != SyntheticAIFixture.segments.count))
            }
            if showPayload {
                DisclosureGroup("Fragmentos y contexto que se enviarán", isExpanded: .constant(true)) {
                    Text(segments.map { "\(timestamp($0.start)): \($0.text)" }.joined(separator: "\n\n")).textSelection(.enabled)
                    Divider(); Text(context.isEmpty ? "Sin contexto coincidente en la nota." : context).textSelection(.enabled)
                }.font(.caption)
            }
            Toggle("Enviar automáticamente nuevos fragmentos de esta grabación", isOn: Binding(get: { ai.automaticMediaIDs.contains(job.id) }, set: { ai.setAutomatic($0, media: job) }))
                .font(.caption).disabled(job.syntheticFixture || job.asrQualityWarning != nil || (job.transcript.isEmpty && job.stage != .transcribing && job.stage != .recording))
            Text("Prepara propuestas aproximadamente cada 5 minutos, al terminar una frase. Adelanta el envío si hay mucho texto y espera hasta 7,5 minutos si hay poco. Incluye hasta dos fragmentos previos de contexto. Recibe la transcripción local durante la grabación o desde archivos importados. Se desactiva al cerrar, ante un error o si Whisper repite frases.").font(.caption2).foregroundStyle(.secondary)
            if let error = ai.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AIReviewInspector: View {
    @ObservedObject var ai: AIController
    @ObservedObject var model: Workbench
    private var batches: [AIBatch] { ai.batches.filter { $0.notebookID == model.selectedNotebookID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Propuestas de IA").font(.headline); Spacer()
                    if ai.running { ProgressView().controlSize(.small); Button("Parar envío") { ai.stop() } }
                    else if batches.contains(where: { $0.stage == .queued }) { Button("Continuar cola") { ai.continueQueue(notebookID: model.selectedNotebookID) } }
                }
                Text("Cada lote conserva su proveedor y permiso de edición. Las dudas siempre requieren revisión.").font(.caption).foregroundStyle(.secondary)
                if batches.isEmpty { ContentUnavailableView("Sin propuestas", systemImage: "checkmark.bubble", description: Text("Selecciona fragmentos en Transcripción y pulsa Enviar selección.")) }
                ForEach(batches.reversed()) { batch in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(URL(fileURLWithPath: batch.targetNote).lastPathComponent).font(.subheadline.weight(.semibold)); Spacer(); Text(stage(batch.stage)).font(.caption).foregroundStyle(.secondary) }
                        Text("\(batch.providerConfiguration?.provider.title ?? NotesAIProvider.openCode.title) · \(batch.model)").font(.caption).foregroundStyle(.secondary)
                        if batch.syntheticDemoProvenance != nil { Text(batch.providerConfiguration?.provider == .codexCLI || batch.providerConfiguration?.provider == .antigravity ? "Datos inventados · condiciones de la cuenta externa" : "Datos inventados · retención permitida · entrenamiento prohibido").font(.caption).foregroundStyle(.orange) }
                        Text("\(timestamp(batch.segments.first?.start ?? 0)) · \(batch.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        if let error = batch.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        if [.failed, .interrupted, .cancelled].contains(batch.stage) { Button("Reintentar este lote") { ai.retry(batch.id) }.disabled(ai.running) }
                        ForEach(batch.decisions.filter { $0.resolution == nil }) { decision in AIProposalCard(ai: ai, model: model, batch: batch, decision: decision) }
                        let resolved = batch.decisions.filter { $0.resolution != nil }
                        if !resolved.isEmpty { DisclosureGroup("Revisadas (\(resolved.count))") { ForEach(resolved) { item in Text("\(item.resolution == "applied" ? "Aplicada" : "Fuera de apuntes"): \(item.reason)").font(.caption).foregroundStyle(.secondary) } } }
                        Divider()
                    }
                }
                if let session = model.document, !session.reviews.isEmpty { DisclosureGroup("Revisión de la simulación") { ReviewInspector(model: model, session: session) } }
            }.padding(16)
        }
    }
    private func stage(_ value: AIStage) -> String {
        switch value { case .queued: "En cola"; case .checking: "Verificando límites"; case .sending: "Enviando"; case .ready: "Revisar"; case .failed: "Error"; case .interrupted: "Interrumpido"; case .cancelled: "Cancelado" }
    }
}

struct AIProposalCard: View {
    @ObservedObject var ai: AIController
    @ObservedObject var model: Workbench
    let batch: AIBatch
    let decision: AIDecision
    @State private var text: String
    @State private var quote: String
    init(ai: AIController, model: Workbench, batch: AIBatch, decision: AIDecision) {
        self.ai = ai; self.model = model; self.batch = batch; self.decision = decision
        _text = State(initialValue: decision.text); _quote = State(initialValue: decision.targetQuote ?? "")
    }
    private var excluded: Bool { [.omit, .aside].contains(decision.action) }
    private var candidate: String? { try? AIOutbox.candidate(batch: batch, decision: decision, text: text, quote: quote.isEmpty ? nil : quote) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label(decision.action)).font(.callout.weight(.semibold)).foregroundStyle(decision.action == .uncertain ? Color.orange : Color.primary)
            Text(decision.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup("Transcripción de origen") { Text(batch.segments.filter { decision.sourceIDs.contains($0.id) }.map(\.text).joined(separator: "\n")).font(.caption).textSelection(.enabled) }
            if !excluded {
                if [.correct, .retract].contains(decision.action) { TextField("Cita exacta que se sustituirá", text: $quote).textFieldStyle(.roundedBorder) }
                if decision.action != .retract { TextEditor(text: $text).font(.callout).frame(height: 100).padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)) }
                if let candidate {
                    DisclosureGroup("Ver cambios antes de aplicar") {
                        ForEach(NoteDiff.lines(before: batch.expectedNote, after: candidate).filter { $0.prefix != " " }) { line in
                            Text(line.prefix + " " + line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(line.prefix == "+" ? Color.green : Color.red).textSelection(.enabled)
                        }
                    }
                } else { Text("Confirma el texto o el destino exacto antes de aplicar.").font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Button(excluded ? "Confirmar fuera de apuntes" : "Descartar") { ai.dismiss(batch.id, decision.id) }
                Spacer()
                if !excluded { Button("Aplicar propuesta") { model.applyAI(batch: batch, proposal: decision, text: text, quote: quote.isEmpty ? nil : quote) }.buttonStyle(.borderedProminent).disabled(candidate == nil || model.hasDraft(for: batch.targetNote)) }
            }
            if model.hasDraft(for: batch.targetNote) { Text("Guarda el borrador de esta nota antes de aplicar.").font(.caption).foregroundStyle(.orange) }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func label(_ action: AIAction) -> String {
        switch action { case .add: "Añadir"; case .correct: "Corregir cita"; case .retract: "Retirar cita"; case .omit: "No copiar"; case .aside: "Inciso"; case .priority: "Prioridad indicada"; case .uncertain: "Duda · confirma el sentido" }
    }
}
