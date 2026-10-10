import SwiftUI
import LectureCore

struct NotebookTrashEntry: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var notebookID: String
    var name: String
    var files: [String: String]
    var folders: [String]
    var assets: [String: String]? = nil
}

@MainActor
extension Workbench {
    var activeNotebooks: [Notebook] { orderedNotebooks(notebooks.filter { $0.archivedAt == nil }) }
    var visibleNotes: [String] { notes.filter { projects?.owner(of: $0)?.archivedAt == nil } }
    var canManageFiles: Bool { assistant?.runningNotebookID == nil && ai?.running != true && media?.busy != true && media?.isRecording != true && !busy }
    func loadTrash() throws {
        guard let workspace, FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent("projects/trash.json").path) else { return }
        trash = try JSONDecoder().decode([NotebookTrashEntry].self, from: workspace.readStorage("projects/trash.json"))
    }
    private func saveTrash(_ entries: [NotebookTrashEntry]) throws {
        guard let workspace else { throw ReplayError.missingWorkspace }
        try workspace.writeStorage("projects/trash.json", data: JSONEncoder().encode(entries)); trash = entries
    }
    func deleteNotebook(_ notebook: Notebook) {
        guard canManageFiles, media?.isRecording != true else { return }
        perform {
            try checkpointDrafts(notebook.id)
            var next = notebooks
            guard let index = next.firstIndex(where: { $0.id == notebook.id }) else { return }
            next[index].archivedAt = Date()
            try workspace?.writeStorage("notebooks.json", data: JSONEncoder().encode(next)); notebooks = next
            if engine?.session.notebookID == notebook.id { engine = nil; document = nil; selectedID = nil }
            if selectedNotebookID == notebook.id {
                selectedNote = nil
                selectedFile = nil; selectedFolder = nil
                selectedNotebookID = activeNotebooks.first?.id ?? ""
            }
        }
    }
    func restoreNotebook(_ notebook: Notebook) {
        guard canManageFiles else { return }
        perform {
            var next = notebooks
            guard let index = next.firstIndex(where: { $0.id == notebook.id }) else { return }
            next[index].archivedAt = nil
            try workspace?.writeStorage("notebooks.json", data: JSONEncoder().encode(next)); notebooks = next
            openNotebook(notebook.id)
        }
    }
    func deleteItem(_ path: String, folder: Bool) {
        guard canManageFiles, media?.isRecording != true, let workspace, let projects else { return }
        perform {
            let notebook = folder ? projects.owner(of: path + "/placeholder.md") : projects.owner(of: path)
            guard let notebook, notebook.archivedAt == nil else { throw ReplayError.unsafePath(path) }
            let paths = folder ? try workspace.fileNames().filter { $0.hasPrefix(path + "/") && projects.owner(of: $0)?.id == notebook.id } : [path]
            var directories: [String] = []
            if folder {
                guard !notebooks.contains(where: { $0.rootPrefix == path || $0.rootPrefix.hasPrefix(path + "/") }) else { throw ReplayError.unsafePath(path) }
                directories = try workspace.libraryFolderTree(path)
            }
            try checkpointDrafts(notebook.id, paths: Set(paths))
            let checkpoint = try projects.capture(notebook.id, summary: "Antes de eliminar")
            let files = checkpoint.files.filter { paths.contains($0.key) }
            var assets: [String: String] = [:]
            for filename in paths where !filename.hasSuffix(".md") {
                try NotebookFileLibrary(projects: projects).validate(filename, notebookID: notebook.id)
                let data = try workspace.readFile(filename)
                let hash = digest(data)
                try workspace.writeStorage("projects/asset-blobs/" + hash, data: data)
                assets[filename] = hash
            }
            guard folder || files.count + assets.count == 1 else { throw ReplayError.unsafePath(path) }
            let entry = NotebookTrashEntry(notebookID: notebook.id, name: path, files: files, folders: directories, assets: assets)
            try saveTrash(trash + [entry])
            do {
                if !files.isEmpty {
                    let changes = try files.keys.sorted().map { NotebookFileChange(path: $0, before: try projects.content(files[$0]!), after: nil) }
                    _ = try projects.apply(notebook.id, summary: "Eliminar \(path)", changes: changes, invalidatesProposals: true)
                }
                for filename in assets.keys.sorted() {
                    try workspace.removeAsset(filename, expected: workspace.readStorage("projects/asset-blobs/" + assets[filename]!))
                }
                for directory in directories.sorted(by: { $0.count > $1.count }) { try workspace.removeEmptyFolder(directory) }
            } catch {
                // Keep the recovery entry if any files were removed before a folder conflict.
                refreshProjectFiles(paths)
                throw error
            }
            refreshProjectFiles(paths)
        }
    }
    func restoreTrash(_ entry: NotebookTrashEntry) {
        guard canManageFiles, let workspace, let projects else { return }
        perform {
            guard notebooks.first(where: { $0.id == entry.notebookID })?.archivedAt == nil else {
                throw ReplayError.invalidResponse("Restaura primero el cuaderno desde la papelera.")
            }
            for folder in entry.folders {
                try projects.validate(folder + "/placeholder.md", notebookID: entry.notebookID)
            }
            let disk = try projects.texts(entry.notebookID)
            let changes = try entry.files.keys.sorted().compactMap { path -> NotebookFileChange? in
                try projects.validate(path, notebookID: entry.notebookID)
                let content = try projects.content(entry.files[path]!)
                if let current = disk[path] {
                    guard current == content else { throw ReplayError.conflict }
                    return nil // Safe after an interrupted deletion or restore.
                }
                return .init(path: path, before: nil, after: content)
            }
            var missingAssets: [String: Data] = [:]
            for (path, hash) in entry.assets ?? [:] {
                try NotebookFileLibrary(projects: projects).validate(path, notebookID: entry.notebookID)
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw ReplayError.unsafePath(hash) }
                let data = try workspace.readStorage("projects/asset-blobs/" + hash)
                guard digest(data) == hash else { throw ReplayError.conflict }
                if FileManager.default.fileExists(atPath: try workspace.fileURL(path).path) {
                    guard try workspace.readFile(path) == data else { throw ReplayError.conflict }
                } else { missingAssets[path] = data }
            }
            if !missingAssets.isEmpty { try NotebookFileLibrary(projects: projects).write(.init(files: missingAssets), notebookID: entry.notebookID, summary: "Restaurar archivos") }
            if !changes.isEmpty { _ = try projects.apply(entry.notebookID, summary: "Restaurar \(entry.name)", changes: changes, invalidatesProposals: true) }
            for folder in entry.folders { try workspace.createFolder(folder) }
            try saveTrash(trash.filter { $0.id != entry.id })
            refreshProjectFiles(Array(entry.files.keys) + Array((entry.assets ?? [:]).keys))
            openNotebook(entry.notebookID)
        }
    }
    func permanentlyDeleteTrash(_ entry: NotebookTrashEntry) {
        guard canManageFiles else { return }
        perform {
            guard trash.contains(where: { $0.id == entry.id }) else { throw ReplayError.conflict }
            try saveTrash(trash.filter { $0.id != entry.id })
        }
    }
    func permanentlyDeleteNotebook(_ notebook: Notebook) {
        guard canManageFiles, let workspace, let projects else { return }
        perform {
            guard notebooks.contains(where: { $0.id == notebook.id && $0.archivedAt != nil }),
                  !notebook.id.contains("/"), !notebook.id.hasPrefix(".") else { throw ReplayError.conflict }
            let paths = try workspace.fileNames().filter { projects.owner(of: $0)?.id == notebook.id }
            let files = try paths.map { ($0, try workspace.readFile($0)) }
            let folders = try workspace.folderNames().filter { folder in
                projects.owner(of: folder + "/placeholder")?.id == notebook.id && folder != "Cuadernos" &&
                !notebooks.contains(where: { $0.id != notebook.id && !$0.rootPrefix.isEmpty && $0.rootPrefix.hasPrefix(folder + "/") })
            }
            for (path, bytes) in files {
                try workspace.permanentlyRemoveFile(path, expected: bytes)
                autosaveTasks[path]?.cancel(); autosaveTasks[path] = nil
                drafts[path] = nil; bases[path] = nil
            }
            for folder in folders.sorted(by: { $0.count > $1.count }) { try workspace.removeEmptyFolder(folder) }
            try projects.forgetNotebook(notebook.id)
            try workspace.removeStorageTree("projects/attachments/" + notebook.id)
            try saveTrash(trash.filter { $0.notebookID != notebook.id })
            let remaining = notebooks.filter { $0.id != notebook.id }
            try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(remaining))
            notebooks = remaining
            persistDrafts()
            refreshProjectFiles(paths)
        }
    }
    func clearTrash() {
        guard canManageFiles else { return }
        errorText = nil
        for notebook in notebooks.filter({ $0.archivedAt != nil }) {
            permanentlyDeleteNotebook(notebook)
            if errorText != nil { return }
        }
        for entry in trash {
            permanentlyDeleteTrash(entry)
            if errorText != nil { return }
        }
    }
    func createFolderInside(_ path: String) {
        guard let notebook = projects?.owner(of: path + "/placeholder.md") else { return }
        selectedNotebookID = notebook.id
        let relative = notebook.rootPrefix.isEmpty ? path : String(path.dropFirst(notebook.rootPrefix.count + 1))
        creationInitialName = relative + "/"; creationKind = "carpeta"
    }
}

struct NotebookTrashMenu: View {
    @ObservedObject var model: Workbench
    @State private var presented = false
    @State private var query = ""
    @State private var hovered: String?
    @State private var pendingDeletion: TrashDeletion?
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var notebooks: [Notebook] {
        model.notebooks.filter { $0.archivedAt != nil && matches($0.name) }
    }
    private var entries: [NotebookTrashEntry] { model.trash.reversed().filter { matches($0.name) } }
    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query)
    }
    var body: some View {
        Button { query = ""; presented.toggle() } label: {
            Image(systemName: "trash").offset(y: -1).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(ControlHoverBackground())
            .accessibilityLabel(text("Papelera · restaurar elementos", "Trash · restore items"))
            .help(text("Papelera · restaurar elementos", "Trash · restore items"))
            .accessibilityIdentifier("notebook.trash")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text("Papelera", "Trash")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(text("Buscar elementos…", "Search items…"), text: $query)
                            .textFieldStyle(.plain).accessibilityIdentifier("notebook.trash.search")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel(text("Borrar búsqueda", "Clear search"))
                        }
                    }.padding(9)
                    Divider()
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(notebooks) { notebook in
                                trashRow(id: "notebook." + notebook.id, name: notebook.name,
                                    detail: text("Cuaderno", "Notebook"), symbol: "book.closed", enabled: model.canManageFiles, delete: { pendingDeletion = .notebook(notebook) }) {
                                    model.restoreNotebook(notebook)
                                    model.notebookRevealRequest += 1
                                }
                            }
                            ForEach(entries) { entry in
                                let owner = model.notebooks.first { $0.id == entry.notebookID }
                                let archived = owner?.archivedAt != nil
                                trashRow(id: entry.id, name: URL(fileURLWithPath: entry.name).lastPathComponent,
                                    detail: archived ? text("Restaura primero el cuaderno", "Restore the notebook first") : entry.name,
                                    symbol: entry.folders.isEmpty ? LibraryFileIcon.symbol(entry.name) : "folder",
                                    enabled: model.canManageFiles && !archived, delete: { pendingDeletion = .entry(entry) }) {
                                    model.restoreTrash(entry)
                                }
                            }
                            if notebooks.isEmpty && entries.isEmpty {
                                Text(query.isEmpty ? text("Papelera vacía", "Trash is empty") : text("No se encontraron elementos", "No items found"))
                                    .font(.callout).foregroundStyle(.secondary).padding(18).frame(maxWidth: .infinity)
                            }
                        }.padding(.vertical, 4)
                    }.frame(height: min(280, CGFloat(max(1, notebooks.count + entries.count)) * 58))
                    Divider()
                    HStack {
                        Spacer()
                        Button { pendingDeletion = .all } label: {
                            Label(text("Vaciar todo", "Clear all"), systemImage: "trash")
                                .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7)
                        }.buttonStyle(.plain).modifier(ControlHoverBackground())
                            .disabled(!model.canManageFiles || (model.trash.isEmpty && !model.notebooks.contains { $0.archivedAt != nil }))
                            .accessibilityIdentifier("notebook.trash.clearAll")
                    }.padding(.horizontal, 4)
                }.padding(5).frame(width: 320).background(Color(nsColor: .windowBackgroundColor))
                    .background(NotebookAccentCaret()).tint(NotebookAccent.color(accent))
                    .onExitCommand { presented = false }
                    .alert(pendingDeletion?.isAll == true ? text("¿Vaciar toda la papelera?", "Clear all Trash?") : text("¿Eliminar permanentemente?", "Delete permanently?"), isPresented: Binding(
                        get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                        Button(text("Cancelar", "Cancel"), role: .cancel) { pendingDeletion = nil }
                        Button(text("Eliminar permanentemente", "Delete permanently"), role: .destructive) {
                            if let pendingDeletion {
                                switch pendingDeletion {
                                case .notebook(let notebook): model.permanentlyDeleteNotebook(notebook)
                                case .entry(let entry): model.permanentlyDeleteTrash(entry)
                                case .all: model.clearTrash()
                                }
                            }
                            pendingDeletion = nil
                        }
                    } message: {
                        Text(pendingDeletion?.isAll == true
                            ? text("Se eliminarán permanentemente todos los elementos y cuadernos de la papelera. No podrás restaurarlos desde aquí.", "All items and notebooks in Trash will be permanently deleted. You won't be able to restore them from here.")
                            : (pendingDeletion?.name ?? "") + "\n" + text("No podrás restaurar este elemento desde la papelera.", "You won't be able to restore this item from Trash."))
                    }
            }
    }
    private enum TrashDeletion {
        case notebook(Notebook), entry(NotebookTrashEntry), all
        var isAll: Bool { if case .all = self { return true }; return false }
        var name: String {
            switch self { case .notebook(let value): value.name; case .entry(let value): URL(fileURLWithPath: value.name).lastPathComponent; case .all: "" }
        }
    }
    private func trashRow(id: String, name: String, detail: String, symbol: String, enabled: Bool, delete: @escaping () -> Void,
                          restore: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
        Button(action: restore) {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.uturn.backward").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .modifier(SelectorRowBackground(highlighted: hovered == id))
        }.buttonStyle(.plain).disabled(!enabled).onHover { hovered = $0 ? id : nil }
            .help(text("Restaurar ", "Restore ") + name)
            .accessibilityLabel(text("Restaurar ", "Restore ") + name)
            .accessibilityIdentifier("notebook.trash.restore." + id)
        Button(action: delete) {
            Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 28, height: 30)
        }.buttonStyle(.plain).modifier(ControlHoverBackground()).disabled(!model.canManageFiles)
            .help(text("Eliminar permanentemente ", "Delete permanently ") + name)
            .accessibilityLabel(text("Eliminar permanentemente ", "Delete permanently ") + name)
            .accessibilityIdentifier("notebook.trash.delete." + id)
        }
    }
}
