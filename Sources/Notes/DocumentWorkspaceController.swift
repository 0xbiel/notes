import SwiftUI
import LectureCore

@MainActor extension Workbench {
    func persistDocumentWorkspace() {
        do { try workspace?.writeStorage("document-workspace.json", data: JSONEncoder().encode(documentWorkspace)) }
        catch { errorText = error.localizedDescription }
    }

    func restoreDocumentWorkspace() {
        defer { restoringDocumentWorkspace = false }
        guard let workspace, FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent("document-workspace.json").path) else { return }
        do {
            var restored = try JSONDecoder().decode(DocumentWorkspace.self, from: workspace.readStorage("document-workspace.json"))
            guard restored.isValid else { return }
            restored.retainPaths(Set(libraryFiles.filter { projects?.owner(of: $0)?.archivedAt == nil }))
            documentWorkspace = restored
            // Load every visible Markdown buffer before mounting its editor.
            for document in restored.documents where document.path.hasSuffix(".md") {
                let disk = try workspace.readNote(document.path)
                if !hasDraft(for: document.path) { drafts[document.path] = disk; bases[document.path] = disk }
            }
            synchronizeWorkspaceSelection()
        } catch { errorText = error.localizedDescription }
    }

    func trackWorkspaceDocument(_ path: String) {
        guard !selectingWorkspaceTab else { return }
        documentWorkspace.open(path)
        selectingWorkspaceTab = true
        layout = documentWorkspace.focused?.mode ?? "preview"
        selectingWorkspaceTab = false
        showPreferences = false
    }

    func selectWorkspaceTab(_ id: String) {
        guard documentWorkspace.focusedID != id || selectedLibraryPath != documentWorkspace.focused?.path else { return }
        documentWorkspace.select(id)
        synchronizeWorkspaceSelection()
    }

    func synchronizeWorkspaceSelection() {
        guard let document = documentWorkspace.focused else { openNotebook(selectedNotebookID); return }
        selectingWorkspaceTab = true
        defer { selectingWorkspaceTab = false }
        openLibraryFile(document.path)
        layout = document.mode
    }

    func splitWorkspace(_ axis: DocumentSplitAxis, path: String? = nil, before: Bool = false) {
        guard let selected = documentWorkspace.focused, let projects else { return }
        let target = path ?? selected.path
        do {
            guard let owner = projects.owner(of: target), owner.archivedAt == nil else { return }
            try NotebookFileLibrary(projects: projects).validate(target, notebookID: owner.id)
            documentWorkspace.split(path: target, axis: axis, before: before)
            synchronizeWorkspaceSelection()
        } catch { errorText = error.localizedDescription }
    }

    func closeWorkspaceTab(_ id: String) {
        guard let document = documentWorkspace.documents.first(where: { $0.id == id }) else { return }
        saveDraft(named: document.path)
        guard !hasDraft(for: document.path) else { return }
        if let controller = latexEditors[document.path], controller.dirty {
            // LaTeX has its own conflict-checked save and draft recovery.
            do { try controller.save() }
            catch { errorText = error.localizedDescription; return }
            guard !controller.dirty else { return }
        }
        documentWorkspace.close(id)
        synchronizeWorkspaceSelection()
    }

    func expandWorkspacePane(_ id: String) {
        selectWorkspaceTab(id)
        documentWorkspace.toggleExpanded(id)
    }

    func cycleWorkspaceTab(_ offset: Int) {
        let tabs = documentWorkspace.documents
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == documentWorkspace.focusedID }) else { return }
        selectWorkspaceTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func previewDocumentDrop(at point: NSPoint, in window: NSWindow, moving sourceID: String? = nil) {
        let target = DocumentPaneDropSurface.target(at: point, in: window, model: self)
        let allowed = target?.paneID == sourceID ? nil : target
        if documentDropPreview != allowed { documentDropPreview = allowed }
    }

    func openLibraryDocuments(_ items: Set<NotebookSidebarSelection>, at target: DocumentPaneDropTarget) {
        guard !items.isEmpty, let projects else { return }
        let paths = items.compactMap { item -> String? in if case .note(let path) = item { path } else { nil } }.sorted()
        guard paths.count == items.count else { return }
        do {
            for path in paths {
                guard let owner = projects.owner(of: path), owner.archivedAt == nil else { return }
                try NotebookFileLibrary(projects: projects).validate(path, notebookID: owner.id)
            }
            for path in paths {
                if documentWorkspace.insert(path: path, at: target) != nil { synchronizeWorkspaceSelection() }
            }
        } catch { errorText = error.localizedDescription }
    }

    func moveWorkspacePane(_ id: String, to target: DocumentPaneDropTarget) {
        documentWorkspace.move(id, to: target)
        synchronizeWorkspaceSelection()
    }
}
