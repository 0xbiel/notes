import SwiftUI
import LectureCore

@MainActor
final class NotebookAssistantController: ObservableObject {
    @Published private(set) var states: [String: NotebookProjectState] = [:]
    @Published private(set) var runningNotebookID: String?
    @Published private(set) var progress = ""
    @Published private(set) var activities: [NotebookActivity] = []
    @Published private(set) var runningChatID: String?
    private func report(_ title: String) { progress = title; activities.append(.init(title)) }
    @Published var error: String? { didSet { recordedErrorNotebookID = nil } }
    private var recordedErrorNotebookID: String?
    @Published var revision = 0
    @Published private(set) var importingAttachments = false
    let store: NotebookProjectStore
    let transport: NotesProviderTransport
    var generate: ((NotebookTextRequest, AIProviderConfiguration) async throws -> NotebookAssistantResponse)?
    private var worker: Task<Void, Never>?

    init(store: NotebookProjectStore) throws {
        self.store = store; transport = NotesProviderTransport(store: LocalMediaStore(workspace: store.workspace))
        for notebook in store.notebooks {
            var state = try store.loadState(notebook)
            state.chats += state.pendingDrafts ?? []
            state.pendingDrafts = nil
            state.chats.removeAll { $0.messages.isEmpty && $0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.attachments ?? []).isEmpty }
            if !state.chats.contains(where: { $0.id == state.activeChatID }) { state.activeChatID = state.chats.last?.id }
            for i in state.chats.indices where state.chats[i].messages.last?.role == "user" {
                state.chats[i].messages.append(.init(role: "error", text: "Petición interrumpida. Revisa el historial antes de volver a enviar."))
                try store.saveState(state, notebookID: notebook.id)
            }
            try save(state, id: notebook.id)
        }
        store.didChange = { [weak self] in self?.revision += 1 }
    }
    func state(_ notebook: Notebook) -> NotebookProjectState { states[notebook.id] ?? .init() }
    func chat(_ notebook: Notebook) -> NotebookChat? {
        let state = state(notebook)
        return state.chats.first { $0.id == state.activeChatID }
    }
    func unrepresentedError(_ notebook: Notebook) -> String? {
        guard let error else { return nil }
        if recordedErrorNotebookID != nil { return nil }
        let last = chat(notebook)?.messages.last
        return last?.role == "error" && last?.text == error ? nil : error
    }
    func composerError(_ notebook: Notebook) -> String? {
        recordedErrorNotebookID == nil || recordedErrorNotebookID == notebook.id ? error : nil
    }
    private func save(_ state: NotebookProjectState, id: String) throws {
        var persisted = state
        persisted.chats = state.chats.filter { !$0.messages.isEmpty }
        persisted.pendingDrafts = state.chats.filter { $0.messages.isEmpty && (!$0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !($0.attachments ?? []).isEmpty) }
        if !persisted.chats.contains(where: { $0.id == persisted.activeChatID }) && !(persisted.pendingDrafts ?? []).contains(where: { $0.id == persisted.activeChatID }) {
            persisted.activeChatID = persisted.chats.last?.id
        }
        try store.saveState(persisted, notebookID: id); states[id] = state
    }
    func saveProfile(_ profile: NotebookProfile, notebook: Notebook) {
        do { var value = state(notebook); value.profile = profile; try save(value, id: notebook.id) }
        catch { self.error = error.localizedDescription }
    }
    func installCopiedState(_ state: NotebookProjectState, notebook: Notebook) throws { try save(state, id: notebook.id) }
    @discardableResult func newChat(_ notebook: Notebook) throws -> String {
        error = nil
        var value = state(notebook)
        if let empty = value.chats.first(where: { $0.messages.isEmpty && $0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.attachments ?? []).isEmpty }) {
            value.activeChatID = empty.id; try save(value, id: notebook.id); return empty.id
        }
        let chat = NotebookChat(title: UserDefaults.standard.string(forKey: "notes.language") == "en" ? "New chat" : "Nuevo chat")
        value.chats.append(chat); value.activeChatID = chat.id
        try save(value, id: notebook.id); return chat.id
    }
    func matchingChats(_ notebook: Notebook, query: String) -> [NotebookChat] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state(notebook).chats.reversed().filter { chat in
            !chat.messages.isEmpty && (query.isEmpty || chat.title.localizedCaseInsensitiveContains(query)
                || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(query) })
        }
    }
    func deleteChat(_ id: String, notebook: Notebook) throws {
        guard !(runningNotebookID == notebook.id && runningChatID == id) else {
            throw MediaError.invalid(UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Stop the request before deleting this chat." : "Detén la petición antes de eliminar este chat.")
        }
        var value = state(notebook)
        value.chats.removeAll { $0.id == id }
        if value.activeChatID == id { value.activeChatID = value.chats.last?.id }
        try save(value, id: notebook.id)
    }
    func selectChat(_ id: String, notebook: Notebook) {
        do {
            var value = state(notebook)
            guard value.chats.contains(where: { $0.id == id }) else { return }
            value.activeChatID = id; try save(value, id: notebook.id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func setDraft(_ text: String, notebook: Notebook) {
        do {
            if chat(notebook) == nil { try newChat(notebook) }
            var value = state(notebook)
            if let i = value.chats.firstIndex(where: { $0.id == value.activeChatID }) { value.chats[i].draft = text }
            try save(value, id: notebook.id)
        } catch { self.error = error.localizedDescription }
    }
    func importAttachments(_ urls: [URL], notebook: Notebook) {
        guard !importingAttachments else { return }
        do {
            if chat(notebook) == nil { try newChat(notebook) }
            guard let chat = chat(notebook) else { return }
            guard urls.count + (chat.attachments ?? []).count <= NotebookAttachmentImport.maximumFiles else { throw MediaError.invalid("Attach up to 8 files per message.") }
            importingAttachments = true
            let root = store.workspace.root, originalRoot = store.workspace.originalRoot
            Task {
                defer { importingAttachments = false }
                do {
                    let added = try await Task.detached {
                        let workspace = try SafeWorkspace(root: root, originalRoot: originalRoot)
                        return try urls.map { try NotebookAttachmentImport.prepare(url: $0, notebookID: notebook.id, workspace: workspace) }
                    }.value
                    try addAttachments(added, notebook: notebook, chatID: chat.id)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func pasteAttachments(_ providers: [NSItemProvider], notebook: Notebook) {
        guard !importingAttachments else { return }
        do {
            if chat(notebook) == nil { try newChat(notebook) }
            guard let chat = chat(notebook) else { return }
            guard providers.count + (chat.attachments ?? []).count <= NotebookAttachmentImport.maximumFiles else { throw MediaError.invalid("Attach up to 8 files per message.") }
            importingAttachments = true
            let root = store.workspace.root, originalRoot = store.workspace.originalRoot
            Task {
                defer { importingAttachments = false }
                do {
                    var added: [NotebookAttachment] = []
                    for provider in providers {
                        let type = ["public.file-url", "public.png", "public.tiff"].first { provider.hasItemConformingToTypeIdentifier($0) }
                        guard let type else { continue }
                        let data: Data = try await withCheckedThrowingContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                                if let data { continuation.resume(returning: data) }
                                else { continuation.resume(throwing: error ?? MediaError.invalid("Could not read pasted attachment.")) }
                            }
                        }
                        let item = try await Task.detached {
                            let workspace = try SafeWorkspace(root: root, originalRoot: originalRoot)
                            if type == "public.file-url", let url = URL(dataRepresentation: data, relativeTo: nil) {
                                return try NotebookAttachmentImport.prepare(url: url, notebookID: notebook.id, workspace: workspace)
                            }
                            return try NotebookAttachmentImport.prepare(data: data, name: type == "public.tiff" ? "Pasted image.tiff" : "Pasted image.png", notebookID: notebook.id, workspace: workspace)
                        }.value
                        added.append(item)
                    }
                    try addAttachments(added, notebook: notebook, chatID: chat.id)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func addAttachments(_ added: [NotebookAttachment], notebook: Notebook, chatID: String) throws {
        var value = state(notebook)
        guard let index = value.chats.firstIndex(where: { $0.id == chatID }) else { throw MediaError.invalid("Chat no disponible.") }
        let combined = (value.chats[index].attachments ?? []) + added
        guard combined.count <= NotebookAttachmentImport.maximumFiles,
              combined.reduce(0, { $0 + $1.imageCount }) <= NotebookAttachmentImport.maximumImages,
              combined.allSatisfy({ $0.notebookID == notebook.id }) else { throw MediaError.invalid("Attach up to 8 files and 24 images/PDF pages per message.") }
        value.chats[index].attachments = combined
        try save(value, id: notebook.id)
    }
    func removeAttachment(_ id: String, notebook: Notebook) {
        do {
            var value = state(notebook)
            guard let index = value.chats.firstIndex(where: { $0.id == value.activeChatID }) else { return }
            value.chats[index].attachments?.removeAll { $0.id == id }
            try save(value, id: notebook.id)
        } catch { self.error = error.localizedDescription }
    }
    private func append(_ message: NotebookMessage, notebook: Notebook, chatID: String) throws {
        var value = state(notebook)
        guard let i = value.chats.firstIndex(where: { $0.id == chatID }) else { throw MediaError.invalid("Chat no disponible.") }
        value.chats[i].messages.append(message)
        try save(value, id: notebook.id)
    }
    func stop() { worker?.cancel() }
    func waitUntilFinished() async { await worker?.value }

    func send(notebook: Notebook, document: String?, texts: [String: String], configuration: AIProviderConfiguration,
              apply: @escaping ([NotebookFileChange], [String: String], String) throws -> NotebookCheckpoint?) {
        guard runningNotebookID == nil, !importingAttachments, let chat = chat(notebook) else { return }
        let prompt = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !(chat.attachments ?? []).isEmpty else { return }
        do {
            try configuration.validateSending()
            var value = state(notebook)
            guard let i = value.chats.firstIndex(where: { $0.id == chat.id }) else { return }
            let allAttachments = value.chats[i].messages.flatMap { $0.attachments ?? [] } + (chat.attachments ?? [])
            var images = try NotebookAttachmentImport.images(allAttachments, notebookID: notebook.id, workspace: store.workspace)
            if configuration.provider == .openCode && !images.isEmpty { throw MediaError.invalid("This provider does not support image/PDF attachments. Select Codex or Antigravity.") }
            var message = NotebookMessage(role: "user", text: prompt.isEmpty ? (UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Review the attached files." : "Revisa los archivos adjuntos.") : prompt)
            message.attachments = chat.attachments
            value.chats[i].messages.append(message)
            if value.chats[i].messages.count == 1 { value.chats[i].title = String(message.text.prefix(65)) }
            value.chats[i].draft = ""; value.chats[i].attachments = nil
            let library = NotebookFileLibrary(projects: store)
            let libraryFiles = try store.workspace.fileNames().filter { store.owner(of: $0)?.id == notebook.id }
            let language = UserDefaults.standard.string(forKey: "notes.language") ?? "es"
            let candidate = NotebookTextRequest(notebook: notebook, profile: value.profile, messages: value.chats[i].messages, currentDocument: document, texts: texts, language: language, libraryFiles: libraryFiles)
            _ = try candidate.prompt()
            try save(value, id: notebook.id)
            runningNotebookID = notebook.id; runningChatID = chat.id; activities = []; report("Leyendo el cuaderno…"); error = nil
            var request = candidate
            for path in request.documents.keys.sorted() { report("Leyendo · \(path)") }
            worker = Task { [weak self] in
                guard let self else { return }
                defer { self.runningNotebookID = nil; self.runningChatID = nil; self.progress = ""; self.worker = nil }
                do {
                    var redundantRounds = 0
                    var repairRounds = 0
                    for _ in 0..<6 {
                        try Task.checkCancellation()
                        self.report("Preparando cambios…")
                        let response: NotebookAssistantResponse
                        if let generate = self.generate { response = try await generate(request, configuration) }
                        else { response = try await self.transport.sendNotebook(request, configuration: configuration, images: images) }
                        try Task.checkCancellation()
                        if !response.readFiles.isEmpty {
                            guard response.edits.isEmpty else { throw MediaError.invalid("El asistente pidió contexto y cambios a la vez.") }
                            var advanced = false
                            for path in response.readFiles {
                                try library.validate(path, notebookID: notebook.id)
                                guard request.catalog[path] != nil else { throw MediaError.invalid("Documento solicitado inexistente: \(path)") }
                                if request.documents[path] == nil {
                                    self.report("Leyendo · \(path)")
                                    if let text = texts[path] { request.documents[path] = text }
                                    else {
                                        do {
                                            let source = try NotebookLibraryContext.read(path, library: library, notebookID: notebook.id)
                                            request.documents[path] = source.text
                                            if configuration.provider == .openCode && !source.images.isEmpty {
                                                request.documents[path, default: ""] += "\n[This provider cannot read images. Choose an image-capable provider for scanned pages/images.]"
                                            } else if images.count + source.images.count <= NotebookAttachmentImport.maximumImages,
                                                      images.reduce(0, { $0 + $1.data.count }) + source.images.reduce(0, { $0 + $1.data.count }) <= 32 * 1024 * 1024 {
                                                images += source.images
                                            } else { request.documents[path, default: ""] += "\n[Images omitted: request image limit reached. Ask for a smaller excerpt.]" }
                                        } catch { request.documents[path] = "[Source exists but could not be extracted: " + error.localizedDescription + "]" }
                                    }
                                    advanced = true
                                }
                            }
                            request.contextUpdate = (request.language == "en" ? "Requested retrieval completed. Sources available (observe any extraction limits): " : "Lectura completada. Fuentes disponibles (respeta los límites de extracción): ") + request.documents.keys.sorted().joined(separator: ", ") + (request.language == "en" ? ". Use these contents now; do not request them again. Return edits, or ask the user if the task is unclear." : ". Usa estos contenidos ahora, sin volver a pedirlos. Devuelve los cambios o pregunta si la petición es ambigua.")
                            if !advanced {
                                redundantRounds += 1
                                guard redundantRounds < 2 else { throw MediaError.invalid("El asistente repitió una petición de contexto. Acota la petición y vuelve a enviar.") }
                            }
                            continue
                        }
                        let changes: [NotebookFileChange]
                        do { changes = try NotebookAssistantProtocol.changes(response, documents: request.documents) }
                        catch let validation as NotebookEditValidationError {
                            guard repairRounds < 2, let original = texts[validation.path] else { throw validation }
                            try self.store.validate(validation.path, notebookID: notebook.id)
                            repairRounds += 1
                            request.documents[validation.path] = original
                            request.contextUpdate = (request.language == "en"
                                ? "The previous edits were rejected before applying any changes. The current exact source is now in documents for "
                                : "Los cambios anteriores se rechazaron sin aplicar nada. documents contiene ahora el original exacto de ")
                                + validation.path + ". " + (request.language == "en"
                                ? "Repair the response using this source. For a full translation/rewrite, return one edit with create=false, replaceEntireFile=true, find=empty string, replacement=the complete updated Markdown. For partial edits, use unique non-overlapping exact passages from this source. Continue the user's task; do not repeat the rejected edit or ask the user to split it."
                                : "Corrige la respuesta usando este original. Para traducir/reescribir la nota completa devuelve un cambio con create=false, replaceEntireFile=true, find=cadena vacía y replacement=Markdown actualizado completo. Para cambios parciales usa fragmentos exactos, únicos y no solapados del original. Continúa la petición del usuario sin repetir el cambio rechazado ni pedir que divida la tarea.")
                            self.report("Corrigiendo cambios…")
                            continue
                        }
                        try Task.checkCancellation()
                        self.report("Validando y guardando \(changes.count) archivo(s)…")
                        let checkpoint = try apply(changes, request.documents, prompt)
                        let reply = response.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (changes.isEmpty ? "Sin cambios." : "Cambios guardados · \(changes.count) archivo(s).") : response.reply
                        try self.append(.init(role: "assistant", text: reply, files: changes.map(\.path), checkpointID: checkpoint?.id, activities: self.activities, appGenerated: response.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), notebook: notebook, chatID: chat.id)
                        return
                    }
                    throw MediaError.invalid("La petición necesita demasiado contexto. Acótala para continuar.")
                } catch {
                    let message = Task.isCancelled ? "Petición cancelada." : error.localizedDescription
                    self.error = message
                    do {
                        try self.append(.init(role: "error", text: message, activities: self.activities), notebook: notebook, chatID: chat.id)
                        self.recordedErrorNotebookID = notebook.id
                    }
                    catch { self.error = "\(message) · No se pudo guardar el mensaje: \(error.localizedDescription)" }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
extension Workbench {
    var currentNotebook: Notebook { activeNotebooks.first { $0.id == selectedNotebookID } ?? activeNotebooks.first ?? Notebook(id: "empty", name: "", rootPrefix: "__empty__") }
    func openNotebook(_ id: String) {
        guard activeNotebooks.contains(where: { $0.id == id }) else { return }
        if let selectedNote { saveDraft(named: selectedNote) }
        persistDrafts(); selectedNotebookID = id; selectedNote = nil; selectedFile = nil; selectedFolder = nil; previewHeading = nil; showPreferences = false
    }
    func submitNotebookPrompt() {
        guard let assistant, let projects, let ai else { return }
        let notebook = currentNotebook
        do {
            let disk = try projects.texts(notebook.id)
            var effective = disk
            for (path, text) in drafts where projects.owner(of: path)?.id == notebook.id && hasDraft(for: path) { effective[path] = text }
            let snapshot = effective
            assistant.send(notebook: notebook, document: selectedNote, texts: snapshot, configuration: ai.providerSettings.selected) { [weak self] changes, read, prompt in
                guard let self else { throw CancellationError() }
                guard !changes.isEmpty else { return nil }
                for (path, original) in read where disk[path] != nil {
                    guard try self.workspace?.readNote(path) == disk[path], (self.hasDraft(for: path) ? self.drafts[path] : disk[path]) == original else { throw ReplayError.conflict }
                }
                for change in changes {
                    try projects.validate(change.path, notebookID: notebook.id)
                    if change.before == nil, disk[change.path] != nil { throw ReplayError.conflict }
                }
                try self.checkpointDrafts(notebook.id, paths: Set(changes.map(\.path)))
                let checkpoint = try projects.apply(notebook.id, summary: String(prompt.prefix(160)), changes: changes, invalidatesProposals: true)
                self.refreshProjectFiles(changes.map(\.path))
                return checkpoint
            }
        } catch { errorText = error.localizedDescription }
    }
    func checkpointDrafts(_ notebookID: String, paths: Set<String>? = nil) throws {
        guard let projects else { return }
        let changes = try drafts.keys.sorted().compactMap { path -> NotebookFileChange? in
            guard projects.owner(of: path)?.id == notebookID, paths?.contains(path) != false, hasDraft(for: path) else { return nil }
            guard let base = bases[path], try workspace?.readNote(path) == base else { throw ReplayError.conflict }
            return .init(path: path, before: base, after: drafts[path])
        }
        if !changes.isEmpty {
            _ = try projects.apply(notebookID, summary: "Borradores guardados", changes: changes)
            for change in changes { bases[change.path] = change.after; drafts[change.path] = change.after }
            persistDrafts()
        }
    }
    func refreshProjectFiles(_ paths: [String]) {
        guard let workspace else { return }
        do {
            notes = try workspace.noteNames(); libraryFiles = try workspace.fileNames(); folders = try workspace.folderNames()
            for path in paths {
                let text = notes.contains(path) ? try workspace.readNote(path) : nil
                drafts[path] = text; bases[path] = text
            }
            persistDrafts()
            if let selectedNote, !notes.contains(selectedNote) { openNotebook(selectedNotebookID) }
            if let selectedFile, !libraryFiles.contains(selectedFile) { openNotebook(selectedNotebookID) }
            refreshEditorFromDisk()
            try reconcileProjectHistory()
            if let target = engine?.session.targetNote, paths.contains(target) {
                replayTask?.cancel(); busy = false; engine = nil
            }
            ai?.refresh()
        } catch { errorText = error.localizedDescription }
    }
    func reconcileProjectHistory() throws {
        for checkpoint in projects?.checkpoints ?? [] where checkpoint.invalidatesProposals == true {
            let paths = Set(checkpoint.changedFiles)
            try ai?.outbox.invalidate(paths: paths, before: checkpoint.date)
            try editor?.invalidateUndo(paths: paths, before: checkpoint.date)
        }
        ai?.refresh()
    }
    func restoreCheckpoint(_ checkpoint: NotebookCheckpoint) {
        guard let projects, assistant?.runningNotebookID == nil, media?.isRecording != true else { return }
        do {
            try checkpointDrafts(checkpoint.notebookID)
            let restored = try projects.restore(checkpoint)
            refreshProjectFiles(restored.changedFiles)
        } catch { errorText = error.localizedDescription }
    }
    func sessionNote(in notebook: Notebook, title: String = "Grabación") throws -> String {
        guard let workspace else { throw ReplayError.missingWorkspace }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = (notebook.rootPrefix.isEmpty ? "" : notebook.rootPrefix + "/") + title + " " + formatter.string(from: Date())
        var path = stem + ".md", index = 2
        while notes.contains(path) { path = stem + " (\(index)).md"; index += 1 }
        try workspace.createNote(path, text: "# \(title)\n\n")
        notes = try workspace.noteNames(); folders = try workspace.folderNames()
        return path
    }
}
