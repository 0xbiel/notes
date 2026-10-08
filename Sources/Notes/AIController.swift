import SwiftUI
import LectureCore

@MainActor
final class AIController: ObservableObject {
    @Published var batches: [AIBatch] = []
    @Published var running = false
    @Published var error: String?
    @Published var automaticMediaIDs: Set<String> = []
    let outbox: AIOutbox
    let harness: OpenRouterHarness
    let transport: NotesProviderTransport
    @Published var providerSettings: AIProviderSettings
    private var worker: Task<Void, Never>?
    private var latestMedia: [String: MediaJob] = [:]
    private var drainIDs: Set<String> = []
    init(workspace: SafeWorkspace, editor: NotebookEditor) throws {
        outbox = try AIOutbox(workspace: workspace)
        harness = OpenRouterHarness(store: LocalMediaStore(workspace: workspace))
        transport = NotesProviderTransport(store: LocalMediaStore(workspace: workspace))
        providerSettings = try AIProviderSettings.load(in: workspace)
        try outbox.recoverApplications(editor: editor); refresh()
    }
    func refresh() { batches = outbox.batches }
    func saveProviderSettings(_ settings: AIProviderSettings) throws {
        guard !running else { throw MediaError.invalid("Espera a que termine la petición antes de guardar preferencias.") }
        try settings.save(in: outbox.workspace)
        providerSettings = settings
    }
    private func configure(_ batch: inout AIBatch) throws {
        guard batch.stage == .queued, batch.providerConfiguration == nil else { return }
        try providerSettings.selected.validateSending()
        batch.providerConfiguration = providerSettings.selected
        batch.model = providerSettings.selected.model
        try outbox.replace(batch)
    }
    func send(media: MediaJob, ids: Set<String>) {
        do {
            let selected = media.transcript.filter { ids.contains($0.id) }
            guard !selected.isEmpty else { return }
            try providerSettings.selected.validateSending()
            if media.syntheticFixture {
                guard selected == SyntheticAIFixture.segments, media.notebookID == "synthetic", try outbox.workspace.readNote(media.targetNote) == SyntheticAIFixture.note else { throw MediaError.invalid("La demo con retención requiere los cuatro fragmentos y la nota inventada intacta. Crea otra demo si ya la editaste.") }
            }
            // Manual selection never sends adjacent unselected transcript.
            for group in AIOutbox.groups(selected, flush: true) {
                var batch = try outbox.enqueue(media: media, selected: group)
                try configure(&batch)
                if media.syntheticFixture { batch.syntheticDemoProvenance = SyntheticAIFixture.version; try outbox.replace(batch) }
                if batch.stage == .queued { drainIDs.insert(batch.id) }
            }
            refresh(); start()
        } catch { self.error = error.localizedDescription; refresh() }
    }
    func setAutomatic(_ enabled: Bool, media: MediaJob) {
        guard !media.syntheticFixture else { return }
        if enabled {
            do { try providerSettings.selected.validateSending() }
            catch { self.error = error.localizedDescription; return }
        }
        if enabled, let warning = media.asrQualityWarning { error = warning; return }
        if enabled { automaticMediaIDs.insert(media.id); receive(media) }
        else { automaticMediaIDs.remove(media.id) }
    }
    func receive(_ media: MediaJob) {
        latestMedia[media.id] = media
        guard automaticMediaIDs.contains(media.id) else { return }
        if let warning = media.asrQualityWarning {
            automaticMediaIDs.remove(media.id)
            drainIDs.subtract(outbox.batches.filter { $0.mediaID == media.id && $0.stage == .queued }.map(\.id))
            error = warning; return
        }
        do {
            try providerSettings.selected.validateSending()
            let submitted = Set(outbox.batches.filter { $0.mediaID == media.id }.flatMap { $0.segments.map(\.id) })
            let fresh = media.transcript.filter { !submitted.contains($0.id) }
            let groups = AIOutbox.groups(fresh, flush: media.stage == .transcribed)
            for group in groups {
                let prior = media.transcript.filter { $0.end <= (group.first?.start ?? 0) && !group.contains($0) }
                var batch = try outbox.enqueue(media: media, selected: group, prior: prior)
                try configure(&batch)
                if batch.stage == .queued { drainIDs.insert(batch.id) }
            }
            refresh(); start()
        } catch {
            // Backpressure leaves every unsubmitted segment in the transcript.
            self.error = error.localizedDescription; refresh()
        }
    }
    func continueQueue(notebookID: String) {
        drainIDs.formUnion(outbox.batches.filter { $0.notebookID == notebookID && $0.stage == .queued }.map(\.id))
        start()
    }
    func start() {
        guard !running else { return }
        running = true; error = nil
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.worker = nil }
            while !Task.isCancelled, var batch = self.outbox.batches.first(where: { $0.stage == .queued && self.drainIDs.contains($0.id) }) {
                do {
                    batch.stage = .checking; batch.attempts += 1; batch.error = nil
                    try self.outbox.replace(batch); self.refresh()
                    let id = batch.id
                    let configuration = batch.providerConfiguration ?? AIProviderSettings().openCode
                    var result = try await self.transport.send(batch, configuration: configuration, checked: { [weak self] in await self?.markSending(id) })
                    // Other approved edits may have changed the local snapshot
                    // while this request was in flight. Never overwrite it.
                    if let current = self.outbox.batches.first(where: { $0.id == id }) { result.expectedNote = current.expectedNote }
                    try self.outbox.replace(result); self.refresh()
                    self.drainIDs.remove(id)
                    for media in Array(self.latestMedia.values) where self.automaticMediaIDs.contains(media.id) { self.receive(media) }
                } catch {
                    if let current = self.outbox.batches.first(where: { $0.id == batch.id }) { batch = current }
                    batch.stage = Task.isCancelled ? .cancelled : .failed; batch.error = error.localizedDescription
                    try? self.outbox.replace(batch); self.refresh(); self.error = batch.error
                    self.automaticMediaIDs.removeAll(); self.drainIDs.removeAll(); break
                }
            }
        }
    }
    private func markSending(_ id: String) {
        guard var batch = outbox.batches.first(where: { $0.id == id }) else { return }
        batch.stage = .sending
        do { try outbox.replace(batch); refresh() } catch { self.error = error.localizedDescription }
    }
    func retry(_ id: String) {
        guard !running, var batch = outbox.batches.first(where: { $0.id == id }), [.failed, .interrupted, .cancelled].contains(batch.stage) else { return }
        batch.stage = .queued; batch.error = nil
        do { try outbox.replace(batch); drainIDs.insert(batch.id); refresh(); start() } catch { self.error = error.localizedDescription }
    }
    func stop() { automaticMediaIDs.removeAll(); drainIDs.removeAll(); worker?.cancel() }
    func dismiss(_ batch: String, _ proposal: String) {
        do { try outbox.dismiss(batchID: batch, proposalID: proposal); refresh() } catch { self.error = error.localizedDescription }
    }
}

@MainActor
extension Workbench {
    func createAIDemo() {
        guard let workspace, let media else { return }
        do {
            let notebook: Notebook
            if let existing = notebooks.first(where: { $0.id == "synthetic" }) { notebook = existing }
            else {
                notebook = Notebook(id: "synthetic", name: "Demo IA inventada", rootPrefix: "Cuadernos/Demo IA " + String(UUID().uuidString.prefix(8)))
                try workspace.createFolder(notebook.rootPrefix)
                var next = notebooks; next.append(notebook)
                try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(next)); notebooks = next
            }
            let note = notebook.rootPrefix + "/Ejemplo " + String(UUID().uuidString.prefix(8)) + ".md"
            try workspace.createNote(note, text: SyntheticAIFixture.note)
            var job = MediaJob(notebookID: "synthetic", subject: notebook.name, note: note, sourceName: "Demo IA · texto inventado")
            job.syntheticFixture = true; job.stage = .transcribed; job.transcript = SyntheticAIFixture.segments
            try media.addAIDemo(job)
            notes = try workspace.noteNames(); folders = try workspace.folderNames(); openNote(note)
            selectedTab = "replay"; showInspector = true
            statusText = "Demo inventada · selecciona los cuatro fragmentos antes de enviar; permite retención, no entrenamiento"
        } catch { errorText = error.localizedDescription }
    }
    func applyAI(batch: AIBatch, proposal: AIDecision, text: String, quote: String?) {
        guard let ai, let editor else { return }
        do {
            let change = try ai.outbox.apply(batchID: batch.id, proposalID: proposal.id, text: text, quote: quote, editor: editor, hasDraft: hasDraft(for: batch.targetNote))
            bases[change.filename] = change.after; drafts[change.filename] = change.after; persistDrafts()
            ai.refresh(); refreshEditorFromDisk()
            do { try engine?.acknowledgeEditorSave(filename: change.filename, before: change.before, after: change.after) }
            catch { statusText = "Propuesta guardada. La sesión sintética antigua tiene un conflicto." }
            inspectorHistoryMode = "editor"; statusText = "Propuesta aplicada · puedes deshacer en Versiones"
        } catch { errorText = error.localizedDescription; ai.refresh(); refreshEditorFromDisk() }
    }
}
