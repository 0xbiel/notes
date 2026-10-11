import SwiftUI
import Combine
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
                Button("Nuevo documento LaTeX") { model.creationInitialName = ""; model.creationKind = "latex" }
            }
            CommandGroup(after: .saveItem) {
                Button("Guardar nota en la copia") { model.saveDraft() }.keyboardShortcut("s").disabled(!model.isDirty)
            }
            CommandGroup(replacing: .printItem) {
                Button("Imprimir…") { model.printSelectedDocument() }.keyboardShortcut("p").disabled(!model.canPrintDocument)
                Button("Exportar PDF…") { model.exportSelectedPDF() }.disabled(model.selectedLibraryPath.map { !["md", "tex"].contains(URL(fileURLWithPath: $0).pathExtension) } ?? true)
            }
            CommandMenu("Notas") {
                Button("Abrir nota…") { model.showQuickOpen = true }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Buscar nota…") { model.showQuickOpen = true }.keyboardShortcut("t")
            }
        }
    }
}

@MainActor
final class Workbench: ObservableObject {
    var latexEditors: [String: LaTeXEditorController] = [:]
    @Published var sessions: [SessionDocument] = []
    @Published var selectedID: String?
    @Published var document: SessionDocument?
    @Published var notes: [String] = []
    @Published var libraryFiles: [String] = []
    @Published var selectedFile: String?
    @Published var selectedFolder: String?
    /// A collapsed folder or notebook a drag has rested on; its row opens.
    @Published var libraryExpandRequest: NotebookSidebarSelection?
    @Published var librarySelections: Set<NotebookSidebarSelection> = []
    @Published var documentChatVisible = false
    @Published var folders: [String] = []
    @Published var noteText = ""
    @Published var errorText: String?
    @Published var busy = false
    @Published var showQuickOpen = false
    @Published var showPreferences = false
    var requestedPreferencesSection: NotebookPreferencesSection = .general
    @Published var creationKind: String?
    @Published var renamingItem: NotebookSidebarSelection?
    @Published var creationInitialName = ""
    @Published var layout = "preview"
    @Published var hideStudyComposer = false
    @Published var trash: [NotebookTrashEntry] = []
    @Published var notebooks: [Notebook] = [.copiedCourse] { didSet { projects?.notebooks = notebooks } }
    @Published var notebookOrdering = NotebookOrdering()
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
    var workspace: SafeWorkspace?
    @Published var media: MediaController?
    var notebookWebEnabled: Bool { assistant?.state(currentNotebook).profile.allowsWebSearch ?? true }
    @Published var dictationActive = false
    private var dictationObservation: AnyCancellable?
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
            if let media {
                dictationObservation = media.$isRecording.combineLatest(media.$busy)
                    .map { $0 || $1 }.removeDuplicates()
                    .sink { [weak self] active in self?.dictationActive = active }
            }
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
                media?.onTranscriptUpdate = { [weak self] job in self?.receiveDictation(job) }
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
            try loadNotebookOrdering()
            let projects = try NotebookProjectStore(workspace: workspace, notebooks: notebooks)
            self.projects = projects
            notes = try workspace.noteNames(); libraryFiles = try workspace.fileNames(); folders = try workspace.folderNames()
            assistant = try NotebookAssistantController(store: projects)
            assistant?.onLibraryChange = { [weak self] paths in self?.refreshProjectFiles(paths) }
            assistant?.dispatchQueued = { [weak self] notebook, chatID, item in
                self?.dispatchNotebookPrompt(notebook: notebook, chatID: chatID, item: item)
            }
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
            if let session = sessions.first(where: { visibleNotes.contains($0.targetNote) }) { select(session.id) }
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

    struct DictationTarget {
        var notebook: Notebook
        var chatID: String
        var jobID: String
        var delivered: Set<String> = []
    }
    var dictationTarget: DictationTarget?
    func toggleMicrophone() {
        guard let media, let assistant else { return }
        if media.isRecording { media.stopMicrophone(); return }
        guard !media.busy, !activeNotebooks.isEmpty else { return }
        guard media.available(for: nil) else {
            requestedPreferencesSection = .transcription; showPreferences = true; return
        }
        do {
            let notebook = currentNotebook
            let chatID = try assistant.chat(notebook)?.id ?? assistant.newChat(notebook)
            let jobID = UUID().uuidString
            dictationTarget = DictationTarget(notebook: notebook, chatID: chatID, jobID: jobID)
            hideStudyComposer = false
            media.startMicrophone(notebook: notebook, note: "", dictationID: jobID)
        } catch { errorText = error.localizedDescription }
    }
    func receiveDictation(_ job: MediaJob) {
        guard var target = dictationTarget, target.jobID == job.id, let assistant else { return }
        let fresh = job.transcript.filter { !target.delivered.contains($0.id) }
        do {
            if !fresh.isEmpty {
                try assistant.appendDictation(fresh.map(\.text).joined(separator: " "), notebook: target.notebook, chatID: target.chatID)
                target.delivered.formUnion(fresh.map(\.id))
            }
            dictationTarget = job.stage == .transcribed ? nil : target
        } catch { dictationTarget = nil; media?.error = error.localizedDescription; media?.stopMicrophone() }
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

}
