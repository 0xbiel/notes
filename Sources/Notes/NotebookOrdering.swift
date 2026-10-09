import SwiftUI
import AppKit
import LectureCore

enum NotebookSortOrder: String, Codable, CaseIterable {
    case manual, alphabetical, modified
    var title: LocalizedStringKey {
        switch self {
        case .manual: "Orden manual"
        case .alphabetical: "Orden alfabético"
        case .modified: "Última modificación"
        }
    }
}

struct NotebookOrdering: Codable {
    var sort: NotebookSortOrder = .manual
    var manualIDs: [String] = []
}

@MainActor
extension Workbench {
    func loadNotebookOrdering() throws {
        guard let workspace, FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent("notebook-order.json").path) else { return }
        notebookOrdering = try JSONDecoder().decode(NotebookOrdering.self, from: workspace.readStorage("notebook-order.json"))
    }
    func setNotebookSort(_ sort: NotebookSortOrder) {
        var next = notebookOrdering
        next.sort = sort
        persistNotebookOrdering(next)
    }
    private func persistNotebookOrdering(_ next: NotebookOrdering) {
        do {
            guard let workspace else { throw ReplayError.missingWorkspace }
            try workspace.writeStorage("notebook-order.json", data: JSONEncoder().encode(next))
            notebookOrdering = next
        } catch { errorText = error.localizedDescription }
    }
    @discardableResult func reorderNotebook(_ id: String, relativeTo target: String, after: Bool = false) -> Bool {
        let displayed = activeNotebooks.map(\.id)
        guard id != target, displayed.contains(id), displayed.contains(target) else { return false }
        var reordered = displayed.filter { $0 != id }
        guard let index = reordered.firstIndex(of: target) else { return false }
        reordered.insert(id, at: index + (after ? 1 : 0))
        var next = notebookOrdering
        next.sort = .manual
        next.manualIDs = reordered
        persistNotebookOrdering(next)
        return notebookOrdering.sort == .manual && notebookOrdering.manualIDs == reordered
    }
    func orderedNotebooks(_ active: [Notebook]) -> [Notebook] {
        let ranks = Dictionary(notebookOrdering.manualIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let originalRanks = Dictionary(notebooks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        let manual = active.sorted {
            let lhs = ranks[$0.id] ?? (ranks.count + (originalRanks[$0.id] ?? 0))
            let rhs = ranks[$1.id] ?? (ranks.count + (originalRanks[$1.id] ?? 0))
            return lhs < rhs
        }
        switch notebookOrdering.sort {
        case .manual: return manual
        case .alphabetical:
            return manual.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modified:
            let dates = Dictionary(active.map { ($0.id, notebookModifiedAt($0)) }, uniquingKeysWith: max)
            return manual.sorted { (dates[$0.id] ?? .distantPast) > (dates[$1.id] ?? .distantPast) }
        }
    }
    private func notebookModifiedAt(_ notebook: Notebook) -> Date {
        guard let workspace else { return .distantPast }
        var latest = projects?.timeline(notebook.id).last?.date ?? .distantPast
        for path in fileNames(in: notebook) {
            if let url = try? workspace.fileURL(path),
               let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                latest = max(latest, date)
            }
        }
        for path in folderNames(in: notebook) + (notebook.rootPrefix.isEmpty ? [] : [notebook.rootPrefix]) {
            guard let url = try? workspace.fileURL(path) else { continue }
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { latest = max(latest, date) }
        }
        return latest
    }
}

struct NotebookSortSelector: View {
    @ObservedObject var model: Workbench
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        AIOptionSelector(title: language == "en" ? "Sort notebooks" : "Ordenar cuadernos", symbol: "arrow.up.arrow.down", options: [
            .init(id: "manual", title: language == "en" ? "Manual order" : "Orden manual"),
            .init(id: "alphabetical", title: language == "en" ? "Alphabetical order" : "Orden alfabético"),
            .init(id: "modified", title: language == "en" ? "Latest modified" : "Última modificación")
        ], iconOnly: true, selection: Binding(get: { model.notebookOrdering.sort.rawValue }, set: {
            if let order = NotebookSortOrder(rawValue: $0) { model.setNotebookSort(order) }
        })).help(language == "en" ? "Sort notebooks" : "Ordenar cuadernos")
            .accessibilityIdentifier("notebook.sort")
    }
}
