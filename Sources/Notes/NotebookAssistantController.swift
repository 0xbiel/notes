import SwiftUI
import LectureCore

@MainActor
final class NotebookAssistantController: ObservableObject {
    @Published private(set) var states: [String: NotebookProjectState] = [:]
    struct RunKey: Hashable {
        let notebookID: String
        let chatID: String
    }
    struct RunState {
        var progress = ""
        var activities: [NotebookActivity] = []
    }
    @Published private(set) var runs: [RunKey: RunState] = [:]
    // Aggregate accessors are used only by workspace-wide status and file-management guards.
    var runningNotebookID: String? { runs.keys.first?.notebookID }
    var runningChatID: String? { runs.keys.first?.chatID }
    var progress: String { runs.values.first?.progress ?? "" }
    var activities: [NotebookActivity] { runs.values.first?.activities ?? [] }
    var runningCount: Int { runs.count }
    func runningCount(in notebook: Notebook) -> Int { runs.keys.filter { $0.notebookID == notebook.id }.count }
    func isRunning(_ notebook: Notebook, chatID: String? = nil) -> Bool {
        guard let id = chatID ?? chat(notebook)?.id else { return false }
        return runs[RunKey(notebookID: notebook.id, chatID: id)] != nil
    }
    func activities(for notebook: Notebook) -> [NotebookActivity] {
        guard let id = chat(notebook)?.id else { return [] }
        return runs[RunKey(notebookID: notebook.id, chatID: id)]?.activities ?? []
    }
    private func report(_ title: String, run: RunKey, detail: String? = nil, kind: NotebookActivityKind = .status) {
        guard var state = runs[run] else { return }
        state.progress = title
        var activity = NotebookActivity(title)
        activity.detail = detail; activity.kind = kind
        state.activities.append(activity)
        runs[run] = state
    }
    private func report(_ update: NotebookProviderProgress, run: RunKey, round: String) {
        guard var state = runs[run] else { return }
        let id = round + "." + update.id
        state.progress = update.title
        if update.kind == .reasoning, update.detail?.isEmpty == false {
            state.activities.removeAll { $0.id == round + ".provider-start" && $0.detail == nil }
        }
        if let index = state.activities.firstIndex(where: { $0.id == id }) {
            state.activities[index].title = update.title
            state.activities[index].detail = update.detail ?? state.activities[index].detail
            state.activities[index].kind = update.kind; state.activities[index].failed = update.failed
        } else {
            var activity = NotebookActivity(update.title)
            activity.id = id; activity.detail = update.detail; activity.kind = update.kind; activity.failed = update.failed
            state.activities.append(activity)
        }
        runs[run] = state
    }
    @Published var error: String? { didSet { recordedErrorNotebookID = nil; recordedErrorChatID = nil } }
    private var recordedErrorNotebookID: String?
    private var recordedErrorChatID: String?
    @Published var revision = 0
    @Published private(set) var importingAttachments = false
    let store: NotebookProjectStore
    let transport: NotesProviderTransport
    var generate: ((NotebookTextRequest, AIProviderConfiguration) async throws -> NotebookAssistantResponse)?
    var dispatchQueued: ((Notebook, String, NotebookQueuedPrompt) -> Void)?
    /// Files the assistant added to the library outside note edits, such as downloads.
    var onLibraryChange: (([String]) -> Void)?
    private var heldQueues: Set<RunKey> = []
    private var steering: Set<RunKey> = []
    private var workers: [RunKey: Task<Void, Never>] = [:]

    init(store: NotebookProjectStore) throws {
        self.store = store; transport = NotesProviderTransport(store: LocalMediaStore(workspace: store.workspace))
        for notebook in store.notebooks {
            var state = try store.loadState(notebook)
            state.chats += state.pendingDrafts ?? []
            state.pendingDrafts = nil
            state.chats.removeAll { $0.messages.isEmpty && $0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.attachments ?? []).isEmpty && ($0.queuedPrompts ?? []).isEmpty }
            if !state.chats.contains(where: { $0.id == state.activeChatID }) { state.activeChatID = state.chats.last?.id }
            for i in state.chats.indices where state.chats[i].messages.last?.role == "user" {
                state.chats[i].messages.append(.init(role: "error", text: "Petición interrumpida. Revisa el historial antes de volver a enviar."))
                try store.saveState(state, notebookID: notebook.id)
            }
            try save(state, id: notebook.id)
            for chat in state.chats where !(chat.queuedPrompts ?? []).isEmpty {
                heldQueues.insert(RunKey(notebookID: notebook.id, chatID: chat.id))
            }
        }
        store.didChange = { [weak self] in self?.revision += 1 }
    }
    func state(_ notebook: Notebook) -> NotebookProjectState { states[notebook.id] ?? .init() }
    func chat(_ notebook: Notebook) -> NotebookChat? {
        let state = state(notebook)
        return state.chats.first { $0.id == state.activeChatID }
    }
    func isEmptyChat(_ notebook: Notebook) -> Bool {
        chat(notebook)?.messages.isEmpty != false && unrepresentedError(notebook) == nil
    }
    func unrepresentedError(_ notebook: Notebook) -> String? {
        guard let error else { return nil }
        if recordedErrorNotebookID != nil { return nil }
        let last = chat(notebook)?.messages.last
        return last?.role == "error" && last?.text == error ? nil : error
    }
    func composerError(_ notebook: Notebook) -> String? {
        recordedErrorNotebookID == nil || (recordedErrorNotebookID == notebook.id && recordedErrorChatID == chat(notebook)?.id) ? error : nil
    }
    private func save(_ state: NotebookProjectState, id: String) throws {
        var persisted = state
        persisted.chats = state.chats.filter { !$0.messages.isEmpty }
        persisted.pendingDrafts = state.chats.filter { $0.messages.isEmpty && (!$0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !($0.attachments ?? []).isEmpty || !($0.queuedPrompts ?? []).isEmpty) }
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
        if let empty = value.chats.first(where: { $0.messages.isEmpty && $0.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.attachments ?? []).isEmpty && ($0.queuedPrompts ?? []).isEmpty }) {
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
        guard !isRunning(notebook, chatID: id) else {
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
    /// Dictation appends to its original chat, never to whichever chat happens
    /// to be selected when recognition finishes. It never sends a request.
    func appendDictation(_ text: String, notebook: Notebook, chatID: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var value = state(notebook)
        guard let index = value.chats.firstIndex(where: { $0.id == chatID }) else {
            throw MediaError.invalid("El chat del dictado ya no existe. No se ha enviado ningún mensaje.")
        }
        let existing = value.chats[index].draft
        let separator = existing.isEmpty || existing.last?.isWhitespace == true ? "" : " "
        value.chats[index].draft = existing + separator + text
        try save(value, id: notebook.id)
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
    func stop() { heldQueues.formUnion(workers.keys); workers.values.forEach { $0.cancel() } }
    func stop(notebook: Notebook) {
        guard let id = chat(notebook)?.id else { return }
        let key = RunKey(notebookID: notebook.id, chatID: id)
        heldQueues.insert(key)
        workers[key]?.cancel()
    }
    func waitUntilFinished() async {
        while !workers.isEmpty {
            let pending = Array(workers.values)
            for worker in pending { await worker.value }
        }
    }

    func queued(_ notebook: Notebook) -> [NotebookQueuedPrompt] { chat(notebook)?.queuedPrompts ?? [] }
    func enqueue(_ notebook: Notebook, configuration: AIProviderConfiguration, document: String?, webEnabled: Bool = true, steer: Bool = false) {
        guard let chat = chat(notebook), !importingAttachments else { return }
        let text = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !(chat.attachments ?? []).isEmpty else { return }
        do {
            try configuration.validateSending()
            var value = state(notebook)
            guard let i = value.chats.firstIndex(where: { $0.id == chat.id }) else { return }
            let item = NotebookQueuedPrompt(text: text, attachments: chat.attachments ?? [], configuration: configuration, document: document, webEnabled: webEnabled)
            var queue = value.chats[i].queuedPrompts ?? []
            if steer { queue.insert(item, at: 0) } else { queue.append(item) }
            value.chats[i].queuedPrompts = queue
            value.chats[i].draft = ""; value.chats[i].attachments = nil
            try save(value, id: notebook.id)
            let key = RunKey(notebookID: notebook.id, chatID: chat.id)
            if steer, isRunning(notebook) { steering.insert(key); heldQueues.remove(key); workers[key]?.cancel() }
        } catch { self.error = error.localizedDescription }
    }
    func updateQueued(_ notebook: Notebook, id: String, text: String) {
        mutateQueue(notebook) { queue in if let i = queue.firstIndex(where: { $0.id == id }) { queue[i].text = text } }
    }
    func removeQueued(_ notebook: Notebook, id: String) { mutateQueue(notebook) { $0.removeAll { $0.id == id } } }
    func moveQueued(_ notebook: Notebook, id: String, offset: Int) {
        mutateQueue(notebook) { queue in
            guard let i = queue.firstIndex(where: { $0.id == id }), queue.indices.contains(i + offset) else { return }
            queue.swapAt(i, i + offset)
        }
    }
    private func mutateQueue(_ notebook: Notebook, change: (inout [NotebookQueuedPrompt]) -> Void) {
        do {
            var value = state(notebook)
            guard let i = value.chats.firstIndex(where: { $0.id == value.activeChatID }) else { return }
            var queue = value.chats[i].queuedPrompts ?? []; change(&queue); value.chats[i].queuedPrompts = queue
            try save(value, id: notebook.id)
        } catch { self.error = error.localizedDescription }
    }
    func promoteQueued(_ notebook: Notebook, id: String) {
        mutateQueue(notebook) { queue in
            guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
            queue.insert(queue.remove(at: i), at: 0)
        }
        guard let chat = chat(notebook) else { return }
        let key = RunKey(notebookID: notebook.id, chatID: chat.id)
        heldQueues.remove(key)
        if isRunning(notebook) { steering.insert(key); workers[key]?.cancel() }
        else { advanceQueue(notebook, chatID: chat.id) }
    }
    func resumeQueue(_ notebook: Notebook) {
        guard let chat = chat(notebook) else { return }
        heldQueues.remove(RunKey(notebookID: notebook.id, chatID: chat.id))
        advanceQueue(notebook, chatID: chat.id)
    }
    private func advanceQueue(_ notebook: Notebook, chatID: String) {
        let key = RunKey(notebookID: notebook.id, chatID: chatID)
        guard !heldQueues.contains(key), !isRunning(notebook, chatID: chatID),
              let item = state(notebook).chats.first(where: { $0.id == chatID })?.queuedPrompts?.first else { return }
        dispatchQueued?(notebook, chatID, item)
    }

    func send(notebook: Notebook, document: String?, texts: [String: String], configuration: AIProviderConfiguration, chatID: String? = nil, queuedInput: NotebookQueuedPrompt? = nil, webEnabled: Bool = true,
              apply: @escaping ([NotebookFileChange], [String: String], String) throws -> NotebookCheckpoint?) {
        guard !isRunning(notebook, chatID: chatID), !importingAttachments, var chat = state(notebook).chats.first(where: { $0.id == (chatID ?? state(notebook).activeChatID) }) else { return }
        if let queuedInput { chat.draft = queuedInput.text; chat.attachments = queuedInput.attachments }
        let prompt = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !(chat.attachments ?? []).isEmpty else { return }
        do {
            try configuration.validateSending()
            var value = state(notebook)
            guard let i = value.chats.firstIndex(where: { $0.id == chat.id }) else { return }
            let allAttachments = value.chats[i].messages.flatMap { $0.attachments ?? [] } + (chat.attachments ?? [])
            var images = try NotebookAttachmentImport.images(allAttachments, notebookID: notebook.id, workspace: store.workspace)
            if configuration.provider == .openCode && !images.isEmpty { throw MediaError.invalid("This provider does not support image/PDF attachments. Select Codex, Claude or Antigravity.") }
            var message = NotebookMessage(role: "user", text: prompt.isEmpty ? (UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Review the attached files." : "Revisa los archivos adjuntos.") : prompt)
            message.attachments = chat.attachments
            value.chats[i].messages.append(message)
            if value.chats[i].messages.count == 1 { value.chats[i].title = String(message.text.prefix(65)) }
            if let queuedInput { value.chats[i].queuedPrompts?.removeAll { $0.id == queuedInput.id } }
            else { value.chats[i].draft = ""; value.chats[i].attachments = nil }
            let library = NotebookFileLibrary(projects: store)
            let libraryFiles = try store.workspace.fileNames().filter { store.owner(of: $0)?.id == notebook.id }
            let language = UserDefaults.standard.string(forKey: "notes.language") ?? "es"
            var candidate = NotebookTextRequest(notebook: notebook, profile: value.profile, messages: value.chats[i].messages, currentDocument: document, texts: texts, language: language, libraryFiles: libraryFiles)
            candidate.webEnabled = queuedInput?.webEnabled ?? webEnabled
            candidate.nativeWebSearch = configuration.provider.supportsNativeWebSearch
            _ = try candidate.prompt()
            try save(value, id: notebook.id)
            let run = RunKey(notebookID: notebook.id, chatID: chat.id)
            runs[run] = RunState()
            report("Leyendo el cuaderno…", run: run)
            error = nil
            var request = candidate
            for path in request.documents.keys.sorted() { report("Leyendo · \(path)", run: run, detail: path, kind: .tool) }
            let generate = self.generate
            workers[run] = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.runs.removeValue(forKey: run); self.workers.removeValue(forKey: run)
                    self.advanceQueue(notebook, chatID: chat.id)
                }
                do {
                    var redundantRounds = 0
                    var repairRounds = 0
                    // Web rounds are not rationed: research runs until the assistant answers or the user stops it.
                    var rounds = 0
                    while rounds < 12 {
                        try Task.checkCancellation()
                        self.report("Conectando con el proveedor…", run: run)
                        let round = UUID().uuidString
                        let response: NotebookAssistantResponse
                        if let generate { response = try await generate(request, configuration) }
                        else { response = try await self.transport.sendNotebook(request, configuration: configuration, images: images, progress: { [weak self] update in
                            await self?.report(update, run: run, round: round)
                        }) }
                        try Task.checkCancellation()
                        if let actions = response.webActions, !actions.isEmpty {
                            guard request.webEnabled else { throw MediaError.invalid("Web access is off for this chat. Turn it on to let the assistant search.") }
                            for action in actions {
                                try Task.checkCancellation()
                                let title = action.kind == "search" ? "Buscando en la web…" : action.kind == "downloadImage" ? "Descargando imagen…" : action.kind == "downloadFile" ? "Descargando archivo…" : "Leyendo página web…"
                                self.report(title, run: run, detail: action.query.isEmpty ? action.url : action.query, kind: .tool)
                                do {
                                    if action.kind == "downloadFile" {
                                        let file = try await NotebookWebClient().download(action)
                                        let path = try library.availablePath(NotebookWebClient.destination(for: action, name: file.name, notebook: notebook))
                                        try library.write(.init(files: [path: file.data]), notebookID: notebook.id, summary: "Descargar archivo")
                                        request.catalog[path] = "Downloaded library file. Request this exact path in readFiles to read its contents. Source only; cannot be edited."
                                        self.onLibraryChange?([path])
                                        request.webResults.append(.init(action: action, source: file.source, text: "Saved in the notebook as \(path) (\(file.data.count) bytes). Read it with readFiles; link it from notes with a path relative to the note.", localFilePath: path))
                                        continue
                                    }
                                    let result = try await NotebookWebClient().execute(action, workspaceRoot: self.store.workspace.root, originalRoot: self.store.workspace.originalRoot, notebook: notebook)
                                    request.webResults.append(result)
                                } catch {
                                    if Task.isCancelled { throw CancellationError() }
                                    request.webResults.append(.init(action: action, source: action.url, text: "", error: error.localizedDescription))
                                }
                            }
                            request.contextUpdate = "New web results are in webResults. Continue the user's task; cite sources and use successful localImagePath values for image edits."
                            continue
                        }
                        rounds += 1
                        if !response.readFiles.isEmpty {
                            guard response.edits.isEmpty else { throw MediaError.invalid("El asistente pidió contexto y cambios a la vez.") }
                            var advanced = false
                            for entry in response.readFiles {
                                // A long source is read in parts: "file.pdf#pages=12-18" or "file.pdf#find=words".
                                let (file, selection) = request.catalog[entry] != nil ? (entry, nil) : NotebookLibraryContext.parse(entry)
                                let path = selection == nil ? file : entry
                                try library.validate(file, notebookID: notebook.id)
                                guard request.catalog[file] != nil else { throw MediaError.invalid("Documento solicitado inexistente: \(file)") }
                                if request.documents[path] == nil {
                                    self.report("Leyendo · \(path)", run: run, detail: path, kind: .tool)
                                    if selection == nil, let text = texts[path] { request.documents[path] = text }
                                    else {
                                        do {
                                            let source = try NotebookLibraryContext.read(file, selection: selection, library: library, notebookID: notebook.id)
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
                        do { changes = try NotebookAssistantProtocol.changes(response, documents: request.documents, allowDeletion: NotebookAssistantProtocol.deletionAllowed(in: request.messages)) }
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
                            self.report("Corrigiendo cambios…", run: run)
                            continue
                        }
                        try Task.checkCancellation()
                        self.report("Validando y guardando \(changes.count) archivo(s)…", run: run, detail: changes.isEmpty ? "Sin cambios en los documentos." : changes.map(\.path).joined(separator: "\n"), kind: .tool)
                        let outputs = try NotebookDocumentOutputWriter.prepare(response.outputs ?? [], documents: request.documents, changes: changes, store: self.store, notebook: notebook)
                        let checkpoint = try apply(changes, request.documents, prompt)
                        try NotebookDocumentOutputWriter.publish(outputs, workspace: self.store.workspace)
                        let outputPaths = outputs.map { $0.0 }
                        if !outputPaths.isEmpty { self.onLibraryChange?(outputPaths) }
                        let reply = response.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (changes.isEmpty ? "Sin cambios." : "Cambios guardados · \(changes.count) archivo(s).") : response.reply
                        let receipt = outputPaths.isEmpty ? reply : reply + "\n\nGenerated files: " + outputPaths.joined(separator: ", ")
                        try self.append(.init(role: "assistant", text: receipt, files: changes.map(\.path) + outputPaths, checkpointID: checkpoint?.id, activities: self.runs[run]?.activities ?? [], appGenerated: response.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), notebook: notebook, chatID: chat.id)
                        return
                    }
                    throw MediaError.invalid("La petición necesita demasiado contexto. Acótala para continuar.")
                } catch {
                    if Task.isCancelled, self.steering.remove(run) != nil { return }
                    self.heldQueues.insert(run)
                    let message = Task.isCancelled ? "Petición cancelada." : error.localizedDescription
                    self.error = message
                    do {
                        try self.append(.init(role: "error", text: message, activities: self.runs[run]?.activities ?? []), notebook: notebook, chatID: chat.id)
                        self.recordedErrorNotebookID = notebook.id
                        self.recordedErrorChatID = chat.id
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
        persistDrafts(); librarySelections = [.notebook(id)]; selectedNotebookID = id; selectedNote = nil; selectedFile = nil; selectedFolder = nil; previewHeading = nil; showPreferences = false
    }
    @discardableResult func openNotebookForNewChat(_ id: String) -> Bool {
        guard let notebook = activeNotebooks.first(where: { $0.id == id }), let assistant else { return false }
        do {
            try assistant.newChat(notebook)
            openNotebook(id)
            notebookRevealRequest += 1
            return true
        } catch { errorText = error.localizedDescription; return false }
    }
    func submitNotebookPrompt() {
        guard media?.isRecording != true, media?.busy != true else { return }
        guard let assistant, projects != nil, let ai else { return }
        let notebook = currentNotebook
        assistant.dispatchQueued = { [weak self] notebook, chatID, item in
            self?.dispatchNotebookPrompt(notebook: notebook, chatID: chatID, item: item)
        }
        if assistant.isRunning(notebook) {
            assistant.enqueue(notebook, configuration: ai.providerSettings.selected, document: selectedLibraryPath, webEnabled: notebookWebEnabled)
            return
        }
        dispatchNotebookPrompt(notebook: notebook, chatID: nil, item: nil)
    }
    func resumeNotebookQueue() {
        guard let assistant else { return }
        assistant.dispatchQueued = { [weak self] notebook, chatID, item in self?.dispatchNotebookPrompt(notebook: notebook, chatID: chatID, item: item) }
        assistant.resumeQueue(currentNotebook)
    }
    func steerNotebookPrompt() {
        guard media?.isRecording != true, media?.busy != true else { return }
        guard let assistant, let ai else { return }
        assistant.enqueue(currentNotebook, configuration: ai.providerSettings.selected, document: selectedLibraryPath, webEnabled: notebookWebEnabled, steer: true)
    }
    func dispatchNotebookPrompt(notebook: Notebook, chatID: String?, item: NotebookQueuedPrompt?) {
        guard let assistant, let projects, let ai else { return }
        do {
            let disk = try projects.texts(notebook.id)
            var effective = disk
            for (path, text) in drafts where projects.owner(of: path)?.id == notebook.id && hasDraft(for: path) { effective[path] = text }
            let snapshot = effective
            assistant.send(notebook: notebook, document: item == nil ? selectedLibraryPath : item?.document, texts: snapshot, configuration: item?.configuration ?? ai.providerSettings.selected, chatID: chatID, queuedInput: item, webEnabled: notebookWebEnabled) { [weak self] changes, read, prompt in
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
            let previousTexts = drafts
            for path in paths {
                let text = notes.contains(path) ? try workspace.readNote(path) : nil
                drafts[path] = text; bases[path] = text
            }
            for path in paths {
                synchronizeDocumentImages(previous: previousTexts[path] ?? "", current: drafts[path] ?? "", note: path)
            }
            persistDrafts()
            if let selectedNote, !notes.contains(selectedNote) { openNotebook(selectedNotebookID) }
            if let selectedFile, !libraryFiles.contains(selectedFile) { openNotebook(selectedNotebookID) }
            refreshEditorFromDisk()
            try reconcileProjectHistory()
            if let target = engine?.session.targetNote, paths.contains(target) {
                busy = false; engine = nil
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
