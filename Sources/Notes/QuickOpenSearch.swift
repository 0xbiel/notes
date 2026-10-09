import Foundation

enum QuickOpenResult: Hashable, Identifiable {
    case notebook(String)
    case file(String)
    case preferences
    var id: Self { self }
}

@MainActor extension Workbench {
    func quickOpenMatches(_ query: String) -> [QuickOpenResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String) -> Bool {
            query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
        }
        let notebooks = activeNotebooks.filter { matches($0.name) }.map { QuickOpenResult.notebook($0.id) }
        let files = libraryFiles.filter { projects?.owner(of: $0)?.archivedAt == nil && matches($0) }.map { QuickOpenResult.file($0) }
        let preferences = query.isEmpty || ["Preferences", "Settings", "Preferencias", "Ajustes", "Theme", "Tema"].contains(where: matches)
        return notebooks + files + (preferences ? [.preferences] : [])
    }

    func openQuickOpenResult(_ result: QuickOpenResult) {
        showQuickOpen = false
        switch result {
        case .notebook(let id):
            guard activeNotebooks.contains(where: { $0.id == id }) else { return }
            openNotebook(id)
            notebookRevealRequest += 1
        case .file(let path): showPreferences = false; openLibraryFile(path)
        case .preferences: showPreferences = true
        }
    }
}
