import AppKit
import LectureCore

struct NotebookClipboardReference: Codable {
    var workspace: String
    var archiveID: String
}
struct NotebookClipboardArchive: Codable {
    var name: String
    var notebook: Bool
    var files: [String: Data]
    var folders: [String]
    var state: NotebookProjectState?
    var attachments: [String: Data] = [:]
}

@MainActor
extension Workbench {
    static let libraryClipboardType = NSPasteboard.PasteboardType("local.palladium.library-items")
    var selectedLibraryPath: String? { selectedNote ?? selectedFile }
    var chatHistoryVisible: Bool { selectedLibraryPath == nil || documentChatVisible }
    var librarySelection: NotebookSidebarSelection {
        selectedFolder.map { .folder($0) } ?? selectedLibraryPath.map { .note($0) } ?? .notebook(selectedNotebookID)
    }
    var libraryDestination: String {
        selectedFolder ?? selectedLibraryPath.map { $0.components(separatedBy: "/").dropLast().joined(separator: "/") } ?? currentNotebook.rootPrefix
    }
    func fileNames(in notebook: Notebook) -> [String] { libraryFiles.filter { projects?.owner(of: $0)?.id == notebook.id } }
    func openLibraryFile(_ path: String) {
        if path.hasSuffix(".md") { openNote(path); return }
        guard let projects, let notebook = projects.owner(of: path), notebook.archivedAt == nil else { return }
        perform {
            try NotebookFileLibrary(projects: projects).validate(path, notebookID: notebook.id)
            if let selectedNote { saveDraft(named: selectedNote) }
            selectedNote = nil; selectedFile = path; selectedFolder = nil; selectedNotebookID = notebook.id; showPreferences = false
        }
    }
    func selectLibraryFolder(_ path: String) {
        guard let owner = projects?.owner(of: path + "/placeholder"), owner.archivedAt == nil else { return }
        if selectedNotebookID != owner.id { openNotebook(owner.id) }
        selectedFolder = path
    }
    func chooseLibraryImport(into folder: String, notebookID: String) {
        guard canManageFiles else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Import" : "Importar"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.importLibraryFiles(panel.urls, into: folder, notebookID: notebookID)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    func importLibraryFiles(_ urls: [URL], into folder: String, notebookID: String) {
        guard canManageFiles, let projects else { return }
        perform {
            let library = NotebookFileLibrary(projects: projects)
            var files: [String: Data] = [:], folders: [String] = [], reserved: Set<String> = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let target = try library.availablePath((folder.isEmpty ? "" : folder + "/") + url.lastPathComponent, reserved: reserved)
                reserved.insert(target)
                let item = try library.externalSnapshot(url, destination: target)
                files.merge(item.files) { _, new in new }; folders += item.folders
            }
            try library.write(.init(files: files, folders: folders), notebookID: notebookID, summary: "Importar archivos")
            refreshProjectFiles(Array(files.keys)); openNotebook(notebookID)
            if files.count == 1, let path = files.keys.first { openLibraryFile(path) }
            statusText = "Importado"
        }
    }
    func copyLibraryItem(_ selection: NotebookSidebarSelection, to clipboard: NSPasteboard = .general) {
        guard canManageFiles, let workspace, let projects else { return }
        perform {
            let id: String, path: String?, folder: Bool, prefix: String, name: String, wholeNotebook: Bool
            switch selection {
            case .notebook(let notebookID):
                guard let notebook = activeNotebooks.first(where: { $0.id == notebookID }) else { throw ReplayError.conflict }
                id = notebookID; path = nil; folder = false; prefix = notebook.rootPrefix; name = notebook.name; wholeNotebook = true
            case .note(let filename), .folder(let filename):
                folder = { if case .folder = selection { return true }; return false }()
                guard let notebook = projects.owner(of: folder ? filename + "/placeholder" : filename), notebook.archivedAt == nil else { throw ReplayError.unsafePath(filename) }
                id = notebook.id; path = filename; prefix = filename.components(separatedBy: "/").dropLast().joined(separator: "/")
                name = URL(fileURLWithPath: filename).lastPathComponent; wholeNotebook = false
            }
            for filename in drafts.keys.sorted() where projects.owner(of: filename)?.id == id && hasDraft(for: filename) {
                saveDraft(named: filename)
                guard !hasDraft(for: filename) else { throw ReplayError.conflict }
            }
            let snapshot = try NotebookFileLibrary(projects: projects).snapshot(notebookID: id, path: path, folder: folder)
            func relative(_ path: String) -> String { prefix.isEmpty ? path : String(path.dropFirst(prefix.count + 1)) }
            var archive = NotebookClipboardArchive(name: name, notebook: wholeNotebook,
                files: Dictionary(uniqueKeysWithValues: snapshot.files.map { (relative($0.key), $0.value) }),
                folders: snapshot.folders.filter { $0 != prefix }.map(relative), state: nil)
            if wholeNotebook, let notebook = activeNotebooks.first(where: { $0.id == id }), let assistant {
                archive.state = assistant.state(notebook)
                for chat in archive.state!.chats {
                    for attachment in (chat.attachments ?? []) + chat.messages.flatMap({ $0.attachments ?? [] }) {
                        for filename in ["original"] + (0..<attachment.imageCount).map({ "\($0).png" }) {
                            let path = attachment.storagePrefix + "/" + filename
                            archive.attachments[path] = try workspace.readStorage(path)
                        }
                    }
                }
                for i in archive.state!.chats.indices {
                    for j in archive.state!.chats[i].messages.indices {
                        archive.state!.chats[i].messages[j].files = archive.state!.chats[i].messages[j].files.map(relative)
                        archive.state!.chats[i].messages[j].checkpointID = nil
                    }
                }
            }
            let archiveID = UUID().uuidString
            try workspace.writeStorage("projects/clipboard/\(archiveID).json", data: JSONEncoder().encode(archive))
            let reference = NotebookClipboardReference(workspace: workspace.root.path, archiveID: archiveID)
            clipboard.clearContents(); clipboard.setData(try JSONEncoder().encode(reference), forType: Self.libraryClipboardType)
            if let path {
                let url = try workspace.fileURL(folder ? path + "/placeholder" : path)
                clipboard.writeObjects([(folder ? url.deletingLastPathComponent() : url) as NSURL])
            }
            statusText = "Copiado"
        }
    }
    func pasteLibraryItems(into folder: String, notebookID: String, from clipboard: NSPasteboard = .general) {
        guard canManageFiles, let workspace, let projects else { return }
        if let data = clipboard.data(forType: Self.libraryClipboardType) {
            perform {
                let reference = try JSONDecoder().decode(NotebookClipboardReference.self, from: data)
                guard reference.workspace == workspace.root.path, UUID(uuidString: reference.archiveID) != nil else { throw ReplayError.invalidResponse("Copia este elemento de nuevo en el espacio de trabajo actual.") }
                let archive = try JSONDecoder().decode(NotebookClipboardArchive.self, from: workspace.readStorage("projects/clipboard/\(reference.archiveID).json"))
                try pasteLibraryArchive(archive, into: folder, notebookID: notebookID, library: NotebookFileLibrary(projects: projects))
            }
        } else if let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            importLibraryFiles(urls, into: folder, notebookID: notebookID)
        }
    }
    private func pasteLibraryArchive(_ archive: NotebookClipboardArchive, into folder: String, notebookID: String, library: NotebookFileLibrary) throws {
        guard let workspace, let projects else { throw ReplayError.missingWorkspace }
        var destination = folder, targetID = notebookID
        var createdNotebook: Notebook?
        if archive.notebook {
            var name = archive.name + " copy", index = 2
            while notebooks.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) || FileManager.default.fileExists(atPath: workspace.courseRoot.appendingPathComponent("Cuadernos/" + name).path) {
                name = archive.name + " copy \(index)"; index += 1
            }
            let notebook = Notebook(name: name, rootPrefix: "Cuadernos/" + name)
            _ = try workspace.fileURL(notebook.rootPrefix + "/placeholder")
            destination = notebook.rootPrefix; targetID = notebook.id; createdNotebook = notebook
            // An interrupted copy remains a separate recoverable notebook.
            var pending = notebook; pending.archivedAt = Date()
            try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(notebooks + [pending]))
            notebooks.append(pending)
            projects.notebooks = notebooks.map { $0.id == notebook.id ? notebook : $0 }
        }
        defer { projects.notebooks = notebooks }
        do {
            var mapping: [String: String] = [:], reserved: Set<String> = []
            for root in Set((Array(archive.files.keys) + archive.folders).map({ $0.components(separatedBy: "/")[0] })) {
                let proposed = (destination.isEmpty ? "" : destination + "/") + root
                let path = try library.availablePath(proposed, reserved: reserved); mapping[root] = path; reserved.insert(path)
            }
            func target(_ relative: String) throws -> String {
                let parts = relative.components(separatedBy: "/")
                guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { throw ReplayError.unsafePath(relative) }
                let root = mapping[parts[0]] ?? ((destination.isEmpty ? "" : destination + "/") + parts[0])
                return root + (parts.count > 1 ? "/" + parts.dropFirst().joined(separator: "/") : "")
            }
            if let createdNotebook { try workspace.createFolder(createdNotebook.rootPrefix) }
            let transfer = try NotebookFileTransfer(files: Dictionary(uniqueKeysWithValues: archive.files.map { (try target($0.key), $0.value) }), folders: archive.folders.map(target))
            try library.write(transfer, notebookID: targetID, summary: "Pegar archivos")
            if let createdNotebook {
                var state = archive.state ?? NotebookProjectState()
                var copiedAttachments: [String: NotebookAttachment] = [:]
                func duplicate(_ original: NotebookAttachment) throws -> NotebookAttachment {
                    if let copy = copiedAttachments[original.storagePrefix] { return copy }
                    var copy = original; copy.id = UUID().uuidString; copy.notebookID = createdNotebook.id
                    for filename in ["original"] + (0..<original.imageCount).map({ "\($0).png" }) {
                        guard let bytes = archive.attachments[original.storagePrefix + "/" + filename] else { throw ReplayError.conflict }
                        try workspace.writeStorage(copy.storagePrefix + "/" + filename, data: bytes)
                    }
                    copiedAttachments[original.storagePrefix] = copy; return copy
                }
                for i in state.chats.indices {
                    state.chats[i].attachments = try state.chats[i].attachments?.map(duplicate)
                    for j in state.chats[i].messages.indices {
                        state.chats[i].messages[j].files = try state.chats[i].messages[j].files.map(target)
                        state.chats[i].messages[j].attachments = try state.chats[i].messages[j].attachments?.map(duplicate)
                    }
                }
                try assistant?.installCopiedState(state, notebook: createdNotebook)
                let finished = notebooks.map { $0.id == createdNotebook.id ? createdNotebook : $0 }
                try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(finished))
                notebooks = finished
            }
            refreshProjectFiles(Array(transfer.files.keys)); openNotebook(targetID)
            if !archive.notebook, transfer.files.count == 1, let path = transfer.files.keys.first { openLibraryFile(path) }
            statusText = "Pegado"
        } catch { throw error }
    }
    func moveLibraryItem(_ path: String, folder: Bool, into destination: String, notebookID: String) {
        guard canManageFiles, let projects else { return }
        perform {
            guard !folder || (destination != path && !destination.hasPrefix(path + "/")) else { throw ReplayError.unsafePath(destination) }
            guard let owner = projects.owner(of: folder ? path + "/placeholder" : path) else { throw ReplayError.unsafePath(path) }
            try checkpointDrafts(owner.id)
            let library = NotebookFileLibrary(projects: projects)
            let snapshot = try library.snapshot(notebookID: owner.id, path: path, folder: folder)
            let newRoot = try library.availablePath((destination.isEmpty ? "" : destination + "/") + URL(fileURLWithPath: path).lastPathComponent)
            func mapped(_ name: String) -> String { newRoot + String(name.dropFirst(path.count)) }
            try library.write(.init(files: Dictionary(uniqueKeysWithValues: snapshot.files.map { (mapped($0.key), $0.value) }), folders: snapshot.folders.map(mapped)), notebookID: notebookID, summary: "Mover archivos")
            deleteItem(path, folder: folder); refreshProjectFiles(Array(snapshot.files.keys)); openNotebook(notebookID)
        }
    }
}
