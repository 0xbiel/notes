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
    var activeNotebooks: [Notebook] { notebooks.filter { $0.archivedAt == nil } }
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
    func createFolderInside(_ path: String) {
        guard let notebook = projects?.owner(of: path + "/placeholder.md") else { return }
        selectedNotebookID = notebook.id
        let relative = notebook.rootPrefix.isEmpty ? path : String(path.dropFirst(notebook.rootPrefix.count + 1))
        creationInitialName = relative + "/"; creationKind = "carpeta"
    }
}

struct NotebookTrashMenu: View {
    @ObservedObject var model: Workbench
    var body: some View {
        Menu {
            if model.trash.isEmpty && !model.notebooks.contains(where: { $0.archivedAt != nil }) { Text("Papelera vacía") }
            ForEach(model.notebooks.filter { $0.archivedAt != nil }) { notebook in
                Button { model.restoreNotebook(notebook) } label: { Label(notebook.name, systemImage: "book.closed") }
            }
            ForEach(model.trash.reversed()) { entry in
                Button { model.restoreTrash(entry) } label: { Label(entry.name, systemImage: entry.folders.isEmpty ? "doc.text" : "folder") }
            }
        } label: { Image(systemName: "trash").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton).fixedSize().disabled(!model.canManageFiles)
            .accessibilityLabel("Papelera · restaurar elementos").help("Papelera · restaurar elementos")
            .accessibilityIdentifier("notebook.trash")
    }
}
