import SwiftUI
import LectureCore

@MainActor
extension Workbench {
    var isDirty: Bool {
        guard let selectedNote else { return false }
        return drafts[selectedNote] != nil && drafts[selectedNote] != bases[selectedNote]
    }
    var targetHasDraft: Bool {
        guard let filename = engine?.session.targetNote else { return false }
        return drafts[filename] != nil && drafts[filename] != bases[filename]
    }
    func hasDraft(for filename: String) -> Bool { drafts[filename] != nil && drafts[filename] != bases[filename] }
    func noteNames(in notebook: Notebook) -> [String] {
        if notebook.rootPrefix.isEmpty {
            return notes.filter { name in !notebooks.filter { !$0.rootPrefix.isEmpty }.contains { name.hasPrefix($0.rootPrefix + "/") } }
        }
        return notes.filter { $0.hasPrefix(notebook.rootPrefix + "/") }
    }
    func folderNames(in notebook: Notebook) -> [String] {
        if notebook.rootPrefix.isEmpty {
            return folders.filter { folder in
                folder != "Cuadernos" && !notebooks.filter { !$0.rootPrefix.isEmpty }.contains {
                    folder == $0.rootPrefix || folder.hasPrefix($0.rootPrefix + "/")
                }
            }
        }
        return folders.filter { $0.hasPrefix(notebook.rootPrefix + "/") }
    }
    func openNote(_ name: String, heading: String? = nil) {
        guard let workspace, projects?.owner(of: name)?.archivedAt == nil else { return }
        if let selectedNote, selectedNote != name { saveDraft(named: selectedNote) }
        do {
            let disk = try workspace.readNote(name)
            let dirty = drafts[name] != nil && drafts[name] != bases[name]
            if !dirty { drafts[name] = disk; bases[name] = disk }
            selectedNote = name
            selectedFile = nil; selectedFolder = nil
            draftText = drafts[name] ?? disk
            previewHeading = heading
            if let notebook = notebooks.first(where: { !$0.rootPrefix.isEmpty && name.hasPrefix($0.rootPrefix + "/") }) { selectedNotebookID = notebook.id }
            else { selectedNotebookID = "derecho" }
            draftVersion += 1
        } catch { errorText = error.localizedDescription }
    }
    func refreshEditorFromDisk() {
        guard let name = selectedNote, let workspace else { return }
        let dirty = drafts[name] != nil && drafts[name] != bases[name]
        guard !dirty else { return }
        do {
            let disk = try workspace.readNote(name)
            drafts[name] = disk; bases[name] = disk; draftText = disk
            draftVersion += 1
        } catch { errorText = error.localizedDescription }
    }
    func changeDraft(_ text: String) {
        guard let name = selectedNote else { return }
        draftText = text; drafts[name] = text
        draftVersion += 1
        statusText = ""
        persistDrafts()
        autosaveTasks.removeValue(forKey: name)?.cancel()
        if hasDraft(for: name) {
            autosaveTasks[name] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.saveDraft(named: name)
            }
        }
    }
    func persistDrafts() {
        do { try workspace?.writeStorage("editor-drafts.json", data: JSONEncoder().encode(DraftArchive(drafts: drafts, bases: bases))) }
        catch { errorText = error.localizedDescription }
    }
    func saveDraft() {
        guard let name = selectedNote else { return }
        saveDraft(named: name)
    }
    func flushAutosave() {
        for name in drafts.keys.sorted() where hasDraft(for: name) { saveDraft(named: name) }
    }
    func saveDraft(named name: String) {
        autosaveTasks.removeValue(forKey: name)?.cancel()
        guard let editor, let before = bases[name], let after = drafts[name],
              hasDraft(for: name), projects?.owner(of: name)?.archivedAt == nil else { return }
        perform {
            _ = try editor.save(filename: name, expected: before, replacement: after)
            // Manual edits invalidate pending proposals instead of rebasing them
            // silently onto text the user has changed.
            bases[name] = after; drafts[name] = after
            persistDrafts()
            do { try engine?.acknowledgeEditorSave(filename: name, before: before, after: after) }
            catch {
                // Preserve the saved user edit even if an older replay session is
                // stale; its next write remains blocked by the hash check.
                statusText = "Nota guardada. La sesión antigua necesita revisar su conflicto."
                throw error
            }
            statusText = "Guardado"
        }
    }
    func undoEditor() {
        guard let editor else { return }
        flushAutosave()
        perform {
            if isDirty || editor.history.last(where: { !$0.undone && $0.superseded != true }).map({ hasDraft(for: $0.filename) }) == true {
                throw ReplayError.invalidResponse("Guarda el borrador de la nota afectada antes de deshacer.")
            }
            let change = try editor.undo()
            try ai?.outbox.acknowledgeAppEdit(filename: change.filename, before: change.after, after: change.before)
            try ai?.outbox.recoverApplications(editor: editor); ai?.refresh()
            bases[change.filename] = change.before; drafts[change.filename] = change.before
            persistDrafts()
            openNote(change.filename)
            try engine?.acknowledgeEditorSave(filename: change.filename, before: change.after, after: change.before)
            statusText = "Edición deshecha"
        }
    }
    func createNotebookItem(kind: String, name: String, notebookID: String? = nil, folder: String? = nil) throws {
        guard let workspace else { throw ReplayError.missingWorkspace }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ReplayError.invalidResponse("Introduce un nombre.") }
        if let notebookID, !activeNotebooks.contains(where: { $0.id == notebookID }) {
            throw ReplayError.invalidResponse("El cuaderno ya no está disponible.")
        }
        let notebook = notebooks.first { $0.id == (notebookID ?? selectedNotebookID) } ?? .copiedCourse
        if kind == "cuaderno" {
            guard !clean.contains("/"), !clean.hasPrefix("."), !notebooks.contains(where: { $0.name.lowercased() == clean.lowercased() }) else {
                throw ReplayError.invalidResponse("Usa un nombre de cuaderno único, sin barras.")
            }
            let prefix = "Cuadernos/" + clean
            try workspace.createFolder(prefix)
            let created = Notebook(name: clean, rootPrefix: prefix)
            var next = notebooks; next.append(created)
            try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(next))
            notebooks = next; selectedNotebookID = created.id
            try projects?.capture(created.id, summary: "Inicio")
            openNotebook(created.id)
        } else {
            guard activeNotebooks.contains(where: { $0.id == notebook.id }) else { throw ReplayError.invalidResponse("Crea o restaura un cuaderno primero.") }
            let directory: String
            if let folder {
                guard !clean.contains("/"), !clean.hasPrefix("."),
                      folder == notebook.rootPrefix || folderNames(in: notebook).contains(folder) else {
                    throw ReplayError.invalidResponse("Elige una carpeta del cuaderno y un nombre sin barras.")
                }
                directory = folder
            } else { directory = notebook.rootPrefix }
            let relative = (directory.isEmpty ? "" : directory + "/") + clean
            try projects?.validate(relative.hasSuffix(".md") ? relative : relative + ".md", notebookID: notebook.id)
            if kind == "carpeta" { try workspace.createFolder(relative) }
            else {
                let filename = relative.hasSuffix(".md") ? relative : relative + ".md"
                let title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                try workspace.createNote(filename, text: "# \(title)\n\n")
                notes = try workspace.noteNames(); openNote(filename)
            }
        }
        notes = try workspace.noteNames()
        libraryFiles = try workspace.fileNames()
        folders = try workspace.folderNames()
        statusText = "Creado"
    }
    func openWikilink(_ url: URL) -> OpenURLAction.Result {
        guard let target = NotebookMarkdown.target(url) else {
            // The prototype never opens an external browser. Links remain
            // selectable text for manual use outside the app.
            errorText = "Enlace externo: este prototipo no abre el navegador."
            return .handled
        }
        let name = target.note
        let matches: [String]
        if name.isEmpty { matches = selectedNote.map { [$0] } ?? [] }
        else {
            let candidate = name.hasSuffix(".md") ? name : name + ".md"
            let notebook = notebooks.first { $0.id == selectedNotebookID } ?? .copiedCourse
            matches = noteNames(in: notebook).filter { $0 == candidate || URL(fileURLWithPath: $0).lastPathComponent == candidate }
        }
        guard matches.count == 1, let file = matches.first else {
            errorText = "Enlace interno no resuelto o ambiguo: \(name). No se abrió ningún archivo externo."
            return .handled
        }
        openNote(file, heading: target.heading)
        return .handled
    }
}
