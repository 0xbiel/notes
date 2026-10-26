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
    var showsDocumentComposer: Bool {
        selectedLibraryPath != nil && assistant != nil &&
        !hideStudyComposer
    }
    var chatHistoryVisible: Bool { selectedLibraryPath == nil || documentChatVisible }
    var librarySelection: NotebookSidebarSelection {
        selectedFolder.map { .folder($0) } ?? selectedLibraryPath.map { .note($0) } ?? .notebook(selectedNotebookID)
    }
    var libraryDestination: String {
        selectedFolder ?? selectedLibraryPath.map { $0.components(separatedBy: "/").dropLast().joined(separator: "/") } ?? currentNotebook.rootPrefix
    }
    func fileNames(in notebook: Notebook) -> [String] { libraryFiles.filter { projects?.owner(of: $0)?.id == notebook.id && !NotebookImageStorage.managed($0) } }
    func openLibraryFile(_ path: String) {
        if path.hasSuffix(".md") { openNote(path); return }
        guard let projects, let notebook = projects.owner(of: path), notebook.archivedAt == nil else { return }
        perform {
            try NotebookFileLibrary(projects: projects).validate(path, notebookID: notebook.id)
            if let selectedNote { saveDraft(named: selectedNote) }
            librarySelections = [.note(path)]
            selectedNote = nil; selectedFile = path; selectedFolder = nil; selectedNotebookID = notebook.id; showPreferences = false
        }
    }
    func selectLibraryFolder(_ path: String) {
        guard let owner = projects?.owner(of: path + "/placeholder"), owner.archivedAt == nil else { return }
        if selectedNotebookID != owner.id { openNotebook(owner.id) }
        selectedFolder = path
        librarySelections = [.folder(path)]
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
    func chooseFolderImport(notebookID: String, asNotebook: Bool) {
        guard canManageFiles else { return }
        let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = english ? "Import" : "Importar"
        panel.message = asNotebook
            ? (english ? "Import folder as a new notebook" : "Importar carpeta como nuevo cuaderno")
            : (english ? "Import folder contents into the notebook" : "Importar contenido de carpeta al cuaderno")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importFolderContents(url, notebookID: notebookID, asNotebook: asNotebook)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    func importFolderContents(_ url: URL, notebookID: String, asNotebook: Bool) {
        guard canManageFiles, let projects else { return }
        perform {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ReplayError.unsafePath(url.path)
            }
            let library = NotebookFileLibrary(projects: projects)
            let snapshot = try library.externalSnapshot(url, destination: "Imported")
            func relative(_ path: String) -> String { String(path.dropFirst("Imported/".count)) }
            let archive = NotebookClipboardArchive(name: url.lastPathComponent, notebook: asNotebook,
                files: Dictionary(uniqueKeysWithValues: snapshot.files.map { (relative($0.key), $0.value) }),
                folders: snapshot.folders.filter { $0 != "Imported" }.map(relative), state: nil)
            guard asNotebook || activeNotebooks.contains(where: { $0.id == notebookID }) else { throw ReplayError.conflict }
            let destination = notebooks.first { $0.id == notebookID }?.rootPrefix ?? ""
            try pasteLibraryArchive(archive, into: destination, notebookID: notebookID, library: library, importedNotebook: asNotebook)
            notebookRevealRequest += 1
            statusText = UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Imported" : "Importado"
        }
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
    private func pasteLibraryArchive(_ archive: NotebookClipboardArchive, into folder: String, notebookID: String, library: NotebookFileLibrary, importedNotebook: Bool = false) throws {
        guard let workspace, let projects else { throw ReplayError.missingWorkspace }
        var destination = folder, targetID = notebookID
        var createdNotebook: Notebook?
        if archive.notebook {
            let baseName = archive.name + (importedNotebook ? "" : " copy")
            var name = baseName, index = 2
            while notebooks.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) || FileManager.default.fileExists(atPath: workspace.courseRoot.appendingPathComponent("Cuadernos/" + name).path) {
                name = baseName + " \(index)"; index += 1
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
    func refreshCreationLocations() throws {
        guard let workspace else { throw ReplayError.missingWorkspace }
        folders = try workspace.folderNames()
        libraryFiles = try workspace.fileNames()
    }
    private func validatedRename(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("."), !clean.contains("/"), !clean.contains("\\"), !clean.contains(":"), !clean.contains("\n"), !clean.contains("\0") else {
            throw MediaError.invalid(UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Choose a name without slashes or reserved characters." : "Elige un nombre sin barras ni caracteres reservados.")
        }
        return clean
    }
    func renameNotebook(_ id: String, name: String) throws {
        guard canManageFiles, let workspace, let i = notebooks.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { throw ReplayError.conflict }
        let clean = try validatedRename(name)
        guard !notebooks.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else {
            throw MediaError.invalid(UserDefaults.standard.string(forKey: "notes.language") == "en" ? "A notebook with this name already exists." : "Ya existe un cuaderno con este nombre.")
        }
        var updated = notebooks; updated[i].name = clean
        try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(updated))
        notebooks = updated
    }
    func renameLibraryFolder(_ path: String, name: String) throws { try renameLibraryItem(path, name: name, folder: true) }
    func renameLibraryFile(_ path: String, name: String) throws { try renameLibraryItem(path, name: name, folder: false) }
    private func renameLibraryItem(_ path: String, name: String, folder: Bool) throws {
        guard canManageFiles, let workspace, let projects else { throw ReplayError.conflict }
        var clean = try validatedRename(name)
        if !folder {
            let suffix = (path as NSString).pathExtension
            if !suffix.isEmpty && !clean.lowercased().hasSuffix("." + suffix.lowercased()) { clean += "." + suffix }
        }
        guard !notebooks.contains(where: { $0.rootPrefix == path || $0.rootPrefix.hasPrefix(path + "/") }),
              let owner = projects.owner(of: folder ? path + "/placeholder.md" : path), owner.archivedAt == nil else { throw ReplayError.unsafePath(path) }
        let parent = path.components(separatedBy: "/").dropLast().joined(separator: "/")
        let destination = (parent.isEmpty ? "" : parent + "/") + clean
        if destination == path { return }
        try NotebookFileLibrary(projects: projects).validate(folder ? destination + "/placeholder.md" : destination, notebookID: owner.id)
        let affected = folder ? try workspace.fileNames().filter { $0.hasPrefix(path + "/") } : [path]
        try checkpointDrafts(owner.id, paths: Set(affected))
        _ = try projects.capture(owner.id, summary: "Before renaming " + path)
        let selected = selectedLibraryPath
        let previousFolder = selectedFolder
        func move(_ from: String, _ to: String) throws {
            if folder { try workspace.renameFolder(from, to: to) } else { try workspace.renameFile(from, to: to) }
        }
        try move(path, destination)
        do { _ = try projects.capture(owner.id, summary: "Rename " + path + " → " + destination, invalidatesProposals: true) }
        catch { try move(destination, path); throw error }
        let moved = affected.map { destination + String($0.dropFirst(path.count)) }
        refreshProjectFiles(affected + moved)
        if let selected, selected == path || (folder && selected.hasPrefix(path + "/")) { openLibraryFile(destination + String(selected.dropFirst(path.count))) }
        else if folder, let previousFolder, previousFolder == path || previousFolder.hasPrefix(path + "/") { selectLibraryFolder(destination + String(previousFolder.dropFirst(path.count))) }
        notebookRevealRequest += 1
    }

    func moveLibraryItem(_ path: String, folder: Bool, into destination: String, notebookID: String) {
        moveLibraryItems([folder ? .folder(path) : .note(path)], into: destination, notebookID: notebookID)
    }

    func itemsForMoving(_ item: NotebookSidebarSelection) -> Set<NotebookSidebarSelection> {
        librarySelections.contains(item) ? librarySelections : [item]
    }

    /// Command-click: adds or removes one document or folder. Notebooks never join a group.
    func toggleLibrarySelection(_ item: NotebookSidebarSelection) {
        var next = librarySelections.filter { if case .notebook = $0 { false } else { true } }
        if next.contains(item) { next.remove(item) } else { next.insert(item) }
        selectLibraryGroup(next)
    }

    /// A group chosen with the pointer. One item opens; several only select.
    func selectLibraryGroup(_ items: Set<NotebookSidebarSelection>) {
        guard !items.isEmpty, items != librarySelections else { return }
        if items.count == 1 { setLibrarySelections(items) } else { librarySelections = items }
    }

    /// False when a drop would leave everything in place or put a folder inside itself.
    func libraryMoveIsUseful(_ items: Set<NotebookSidebarSelection>, into directory: String) -> Bool {
        var useful = false
        for item in items {
            let path: String
            switch item {
            case .notebook: continue
            case .note(let value): path = value
            case .folder(let value):
                if directory == value || directory.hasPrefix(value + "/") { return false }
                path = value
            }
            if path.components(separatedBy: "/").dropLast().joined(separator: "/") != directory { useful = true }
        }
        return useful
    }

    func setLibrarySelections(_ values: Set<NotebookSidebarSelection>) {
        // Outline rebuilds can emit stale/empty selections while moved rows are inserted.
        guard !values.isEmpty, values.allSatisfy({ item in
            switch item {
            case .note(let path): return libraryFiles.contains(path)
            case .folder(let path): return folders.contains(path)
            case .notebook(let id): return activeNotebooks.contains { $0.id == id }
            }
        }) else { return }
        librarySelections = values
        // A group only selects; the open document stays as it is.
        guard values.count == 1, let value = values.first else { return }
        switch value {
        case .notebook(let id): openNotebook(id)
        case .note(let path): if libraryFiles.contains(path) { openLibraryFile(path) }
        case .folder(let path): selectLibraryFolder(path)
        }
        librarySelections = values
    }

    func moveLibraryItems(_ selection: Set<NotebookSidebarSelection>, into destination: String, notebookID: String) {
        guard canManageFiles, let projects, let workspace else { return }
        perform {
            let library = NotebookFileLibrary(projects: projects)
            try library.validate((destination.isEmpty ? "" : destination + "/") + "placeholder", notebookID: notebookID)
            let selectedFolders = selection.compactMap { if case .folder(let path) = $0 { return path }; return nil }
            var roots: [(path: String, folder: Bool)] = []
            for item in selection {
                let path: String, folder: Bool
                switch item {
                case .note(let value): path = value; folder = false
                case .folder(let value): path = value; folder = true
                case .notebook: continue
                }
                if selectedFolders.contains(where: { path != $0 && path.hasPrefix($0 + "/") }) { continue }
                guard !folder || (destination != path && !destination.hasPrefix(path + "/")) else { throw ReplayError.unsafePath(destination) }
                if path.components(separatedBy: "/").dropLast().joined(separator: "/") == destination { continue }
                roots.append((path, folder))
            }
            guard !roots.isEmpty else { return }
            roots.sort { $0.path < $1.path }
            var moves: [(from: String, to: String, folder: Bool)] = []
            var affected: [String] = [], owners: Set<String> = [notebookID], reserved: Set<String> = []
            for root in roots {
                guard let owner = projects.owner(of: root.folder ? root.path + "/placeholder" : root.path), owner.archivedAt == nil else { throw ReplayError.unsafePath(root.path) }
                owners.insert(owner.id)
                let snapshot = try library.snapshot(notebookID: owner.id, path: root.path, folder: root.folder)
                guard root.folder || snapshot.files[root.path] != nil else { throw ReplayError.conflict }
                let target = try library.availablePath((destination.isEmpty ? "" : destination + "/") + URL(fileURLWithPath: root.path).lastPathComponent, reserved: reserved)
                reserved.insert(target)
                try library.validate(root.folder ? target + "/placeholder" : target, notebookID: notebookID)
                moves.append((root.path, target, root.folder))
                affected += snapshot.files.keys.flatMap { [$0, target + String($0.dropFirst(root.path.count))] }
            }
            for owner in owners.sorted() { try checkpointDrafts(owner); _ = try projects.capture(owner, summary: "Before moving documents") }
            let originalNotes = try Dictionary(uniqueKeysWithValues: affected.filter { path in
                guard path.hasSuffix(".md") else { return false }
                return FileManager.default.fileExists(atPath: try workspace.noteURL(path).path)
            }.map { ($0, try workspace.readNote($0)) })
            func mapped(_ path: String) -> String {
                guard let move = moves.first(where: { path == $0.from || ($0.folder && path.hasPrefix($0.from + "/")) }) else { return path }
                return move.to + String(path.dropFirst(move.from.count))
            }
            var completed: [(from: String, to: String, folder: Bool)] = []
            var copiedImages: [String: Data] = [:], rewrittenNotes: [String: String] = [:]
            var imageTargets: [String: String] = [:]
            do {
                for move in moves { try workspace.moveLibraryItem(move.from, to: move.to, folder: move.folder); completed.append(move) }
                for (oldNote, original) in originalNotes {
                    let newNote = mapped(oldNote)
                    guard newNote != oldNote else { continue }
                    var replacement = original as NSString
                    for reference in NotebookImageStorage.references(original, note: oldNote, workspace: workspace).reversed() {
                        var target = mapped(reference.path)
                        guard let sourceOwner = projects.owner(of: reference.path), sourceOwner.id == projects.owner(of: oldNote)?.id else { continue }
                        if projects.owner(of: target)?.id != notebookID {
                            if let cached = imageTargets[reference.path] { target = cached }
                            else {
                                let bytes = try workspace.readFile(target)
                                let image = try DocumentImageInput.validated(bytes)
                                let prefix = activeNotebooks.first { $0.id == notebookID }!.rootPrefix
                                let folder: String = prefix.isEmpty ? "" : prefix + "/"
                                target = "\(folder).palladium-images/image-\(UUID().uuidString.lowercased()).\(image.fileExtension)"
                                try workspace.createAsset(target, data: bytes); copiedImages[target] = bytes
                                imageTargets[reference.path] = target
                            }
                        }
                        replacement = replacement.replacingCharacters(in: reference.range, with: NotebookImageStorage.relative(target, from: newNote)) as NSString
                    }
                    if replacement as String != original {
                        rewrittenNotes[newNote] = original
                        try Data((replacement as String).utf8).write(to: workspace.noteURL(newNote), options: .atomic)
                    }
                }
                for owner in owners.sorted() { _ = try projects.capture(owner, summary: "Move documents", invalidatesProposals: true) }
            } catch {
                for (note, text) in rewrittenNotes { try Data(text.utf8).write(to: workspace.noteURL(note), options: .atomic) }
                for (path, bytes) in copiedImages { try workspace.removeAsset(path, expected: bytes) }
                for move in completed.reversed() { try workspace.moveLibraryItem(move.to, to: move.from, folder: move.folder) }
                throw error
            }
            refreshProjectFiles(affected)
            openNotebook(notebookID)
            if !destination.isEmpty { selectedFolder = destination }
            librarySelections = Set(moves.map { $0.folder ? .folder($0.to) : .note($0.to) })
            if moves.count == 1, let move = moves.first {
                if move.folder { selectLibraryFolder(move.to) } else { openLibraryFile(move.to) }
            }
            notebookRevealRequest += 1
            statusText = UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Moved" : "Movido"
        }
    }
}
