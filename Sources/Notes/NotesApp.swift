import SwiftUI
import LectureCore

@main
struct NotesApp: App {
    @StateObject private var model = Workbench()
    @AppStorage("notes.appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("Palladium") {
            WorkbenchView(model: model).frame(minWidth: 600, minHeight: 500)
                .onChange(of: appearance, initial: true) { _, value in
                    // Clear the native override immediately when returning to System.
                    // A nil SwiftUI color-scheme preference can retain the old window appearance.
                    switch value {
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    default: NSApp.appearance = nil
                    }
                }
                .onDisappear { model.flushAutosave(); model.assistant?.stop(); model.ai?.stop(); if model.media?.isRecording == true { model.media?.stopMicrophone() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.flushAutosave() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.flushAutosave(); model.assistant?.stop(); model.ai?.stop(); model.media?.shutdown() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            ChromeCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Preferencias…") { model.showPreferences = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Nueva nota") { model.creationInitialName = ""; model.creationKind = "nota" }.keyboardShortcut("n")
                Button("Nueva sesión sintética") { model.perform { try model.createSession() } }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy)
            }
            CommandGroup(after: .saveItem) {
                Button("Guardar nota en la copia") { model.saveDraft() }.keyboardShortcut("s").disabled(!model.isDirty)
            }
            CommandMenu("Demo") {
                Button("Crear demo IA inventada (permite retención)") { model.createAIDemo() }
                Button(model.busy ? "Detener escucha simulada" : "Iniciar escucha simulada") { model.toggleDemo() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Siguiente fragmento") { model.nextStep() }.keyboardShortcut(".", modifiers: [.command]).disabled(model.busy)
            }
            CommandMenu("Notas") {
                Button("Abrir nota…") { model.showQuickOpen = true }.keyboardShortcut("p")
                Button("Buscar nota…") { model.showQuickOpen = true }.keyboardShortcut("t")
                Button("Mostrar inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Revisar edición") { model.inspectorHistoryMode = "editor"; model.selectedTab = "changes"; model.showInspector = true }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class Workbench: ObservableObject {
    @Published var sessions: [SessionDocument] = []
    @Published var selectedID: String?
    @Published var document: SessionDocument?
    @Published var notes: [String] = []
    @Published var libraryFiles: [String] = []
    @Published var selectedFile: String?
    @Published var selectedFolder: String?
    @Published var documentChatVisible = false
    @Published var folders: [String] = []
    @Published var noteText = ""
    @Published var errorText: String?
    @Published var busy = false
    @Published var selectedTab = "library"
    @Published var showInspector = false
    @Published var showQuickOpen = false
    @Published var showPreferences = false
    @Published var creationKind: String?
    @Published var creationInitialName = ""
    @Published var layout = "preview"
    @Published var hideStudyComposer = false
    @Published var inspectorHistoryMode = "session"
    @Published var trash: [NotebookTrashEntry] = []
    @Published var notebooks: [Notebook] = [.copiedCourse] { didSet { projects?.notebooks = notebooks } }
    @Published var selectedNotebookID = "derecho"
    @Published var notebookRevealRequest = 0
    @Published var selectedNote: String?
    @Published var draftText = ""
    @Published var previewHeading: String?
    @Published var draftVersion = 0
    @Published var statusText = ""
    var drafts: [String: String] = [:]
    var autosaveTasks: [String: Task<Void, Never>] = [:]
    var bases: [String: String] = [:]
    var editor: NotebookEditor?
    var replayTask: Task<Void, Never>?
    var workspace: SafeWorkspace?
    @Published var media: MediaController?
    @Published var ai: AIController?
    var projects: NotebookProjectStore?
    @Published var assistant: NotebookAssistantController?
    @Published var showNotebookManagement = false
    @Published var notebookCheckpointSelection: String?
    var engine: ReplayEngine?

    init(workspaceRoot: URL? = nil) {
        do {
            let arguments = CommandLine.arguments
            let argumentIndex = arguments.firstIndex(of: "--workspace")
            let path: String
            if let workspaceRoot { path = workspaceRoot.path }
            else if let argumentIndex, argumentIndex + 1 < arguments.count { path = arguments[argumentIndex + 1] }
            else if let bundlePath = Bundle.main.object(forInfoDictionaryKey: "PrototypeWorkspace") as? String { path = bundlePath }
            else { throw ReplayError.missingWorkspace }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("original-hashes.json"))) as? [String: Any]
            guard let original = manifest?["originalRoot"] as? String else { throw ReplayError.missingWorkspace }
            let workspace = try SafeWorkspace(root: root, originalRoot: URL(fileURLWithPath: original))
            self.workspace = workspace
            media = try MediaController(workspace: workspace)
            notes = try workspace.noteNames()
            folders = try workspace.folderNames()
            editor = try NotebookEditor(workspace: workspace)
            if let editor {
                ai = try AIController(workspace: workspace, editor: editor)
                ai?.hasDraft = { [weak self] name in self?.hasDraft(for: name) ?? true }
                ai?.onAutomaticEdit = { [weak self] change in
                    guard let self else { return }
                    self.bases[change.filename] = change.after; self.drafts[change.filename] = change.after
                    self.persistDrafts(); self.refreshEditorFromDisk()
                    do { try self.engine?.acknowledgeEditorSave(filename: change.filename, before: change.before, after: change.after) }
                    catch { self.statusText = "Nota guardada; la sesión de simulación tiene un conflicto." }
                }
                media?.onTranscriptUpdate = { [weak self] job in self?.ai?.receive(job) }
            }
            if FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent("editor-drafts.json").path) {
                let archive = try JSONDecoder().decode(DraftArchive.self, from: workspace.readStorage("editor-drafts.json"))
                for name in archive.drafts.keys { _ = try workspace.noteURL(name) }
                for name in archive.bases.keys { _ = try workspace.noteURL(name) }
                drafts = archive.drafts; bases = archive.bases
            }
            if FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent("notebooks.json").path) {
                notebooks = try JSONDecoder().decode([Notebook].self, from: workspace.readStorage("notebooks.json"))
            }
            let projects = try NotebookProjectStore(workspace: workspace, notebooks: notebooks)
            self.projects = projects
            notes = try workspace.noteNames(); libraryFiles = try workspace.fileNames(); folders = try workspace.folderNames()
            assistant = try NotebookAssistantController(store: projects)
            try loadTrash()
            for notebook in notebooks { try projects.capture(notebook.id, summary: "Inicio") }
            projects.installWriteTracking()
            try reconcileProjectHistory()
            media?.createNotebookTarget = { [weak self] notebook in
                guard let self else { throw CancellationError() }
                return try self.sessionNote(in: notebook)
            }
            sessions = try workspace.loadSessions()
            selectedNotebookID = activeNotebooks.first?.id ?? ""
            if sessions.isEmpty { if !visibleNotes.isEmpty { try createSession() } }
            else if let session = sessions.first(where: { visibleNotes.contains($0.targetNote) }) { select(session.id) }
            if let first = visibleNotes.first(where: { $0.hasPrefix("Tema 1") }) ?? visibleNotes.first { openNote(first) }
            else { selectedNote = nil; selectedNotebookID = activeNotebooks.first?.id ?? "" }
        } catch {
            errorText = error.localizedDescription
            if projects == nil {
                let reason = error.localizedDescription
                workspace?.noteMutation = { _, _, _ in throw MediaError.invalid("No se puede editar hasta recuperar el cuaderno: " + reason) }
            }
        }
    }

    func importMedia() {
        let notebook = currentNotebook
        media?.chooseImport(notebook: notebook, note: selectedNote)
        selectedTab = "library"; showInspector = true
    }
    func toggleMicrophone() {
        guard let media else { return }
        if media.isRecording { media.stopMicrophone() }
        else { guard !activeNotebooks.isEmpty else { return }; media.startMicrophone(notebook: currentNotebook, note: selectedNote) }
        selectedTab = "library"; showInspector = true
    }

    func createSession() throws {
        guard let workspace else { throw ReplayError.missingWorkspace }
        let notebook = currentNotebook
        let candidates = noteNames(in: notebook)
        guard let note = selectedNote.flatMap({ candidates.contains($0) ? $0 : nil }) ?? candidates.first(where: { $0.hasPrefix("Provisional") }) ?? candidates.first else {
            throw ReplayError.invalidResponse("Crea una nota en este cuaderno antes de iniciar una sesión.")
        }
        var session = try SyntheticFixtures.newSession(workspace: workspace, note: note)
        session.notebookID = notebook.id
        session.metadata.subject = notebook.name
        try workspace.save(session)
        sessions.insert(session, at: 0)
        select(session.id)
    }

    func select(_ id: String) {
        guard let workspace, let session = sessions.first(where: { $0.id == id }) else { return }
        selectedID = id
        selectedNotebookID = session.notebookID
        engine = ReplayEngine(session: session, workspace: workspace)
        refresh()
    }

    func refresh() {
        guard let engine else { return }
        document = engine.session
        if let i = sessions.firstIndex(where: { $0.id == engine.session.id }) { sessions[i] = engine.session }
        do { noteText = try engine.workspace.readNote(engine.session.targetNote) }
        catch { errorText = error.localizedDescription }
        refreshEditorFromDisk()
    }

    func perform(_ action: () throws -> Void) {
        do { try action(); refresh() }
        catch { errorText = error.localizedDescription; refresh() }
    }

    func replayAll() {
        guard !busy else { return }
        guard let replayID = engine?.session.id else { return }
        busy = true
        replayTask = Task { @MainActor in
            defer { busy = false }
            while !Task.isCancelled, let engine, engine.session.id == replayID, engine.session.replayCursor < SyntheticFixtures.steps.count {
                do { try engine.replayNext(deferApplication: targetHasDraft); refresh() }
                catch { errorText = error.localizedDescription; break }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    func nextStep() { perform { try engine?.replayNext(deferApplication: targetHasDraft) } }
    func toggleDemo() {
        if busy { replayTask?.cancel(); statusText = "Simulación detenida. No se ha usado el micrófono." }
        else {
            if selectedNotebookID != engine?.session.notebookID || selectedNote != engine?.session.targetNote || engine?.session.replayCursor == SyntheticFixtures.steps.count {
                do { try createSession() } catch { errorText = error.localizedDescription; return }
            }
            selectedTab = "replay"; replayAll()
        }
    }
}
