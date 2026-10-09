import SwiftUI
import LectureCore

struct LibraryMoveMenu: View {
    @ObservedObject var model: Workbench
    let path: String
    let folder: Bool
    private var parent: String { path.components(separatedBy: "/").dropLast().joined(separator: "/") }
    var body: some View {
        Menu("Mover a…") {
            ForEach(model.activeNotebooks) { notebook in
                Menu(notebook.name) {
                    destination(notebook.rootPrefix, label: "Raíz del cuaderno", notebook: notebook)
                    ForEach(model.folderNames(in: notebook), id: \.self) { directory in
                        if directory != notebook.rootPrefix {
                            destination(directory, label: notebook.rootPrefix.isEmpty ? directory : String(directory.dropFirst(notebook.rootPrefix.count + 1)), notebook: notebook)
                        }
                    }
                }
            }
        }.disabled(!model.canManageFiles)
    }
    private func destination(_ directory: String, label: String, notebook: Notebook) -> some View {
        Button(label) { model.moveLibraryItem(path, folder: folder, into: directory, notebookID: notebook.id) }
            .disabled(directory == parent || (folder && (directory == path || directory.hasPrefix(path + "/"))))
    }
}
