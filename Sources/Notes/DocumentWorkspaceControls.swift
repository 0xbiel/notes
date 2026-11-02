import SwiftUI

struct DocumentPaneHandle: View {
    @ObservedObject var model: Workbench
    let document: WorkspaceDocument
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        HStack(spacing: 0) {
            DocumentPaneGrip(model: model, documentID: document.id).frame(width: 26, height: 18)
            if model.documentWorkspace.visibleIDs.count > 1 {
                Button { model.expandWorkspacePane(document.id) } label: {
                    Image(systemName: model.documentWorkspace.expandedID == document.id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium)).frame(width: 24, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(t(model.documentWorkspace.expandedID == document.id ? "Restore panes" : "Expand pane",
                            model.documentWorkspace.expandedID == document.id ? "Restaurar paneles" : "Ampliar panel"))
                    .accessibilityLabel(t(model.documentWorkspace.expandedID == document.id ? "Restore panes" : "Expand pane",
                                         model.documentWorkspace.expandedID == document.id ? "Restaurar paneles" : "Ampliar panel"))
                    .accessibilityIdentifier("workspace.expandPane")
            }
            Button { model.closeWorkspaceTab(document.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .frame(width: 24, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(t("Close pane · ⌘W", "Cerrar panel · ⌘W"))
                .accessibilityLabel(t("Close pane", "Cerrar panel"))
                .accessibilityIdentifier("workspace.closePane")
        }
        .foregroundStyle(.secondary)
        .background(.regularMaterial, in: UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
        .contextMenu { DocumentPaneMenuItems(model: model, document: document) }
    }
    private func t(_ en: String, _ es: String) -> String { language == "en" ? en : es }
}

struct DocumentPaneMenuItems: View {
    @ObservedObject var model: Workbench
    let document: WorkspaceDocument
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        Group {
                Text(URL(fileURLWithPath: document.path).lastPathComponent)
                Button(t("Open document…", "Abrir documento…")) { focus(); model.showQuickOpen = true }
                if model.documentWorkspace.documents.count > 1 {
                    Menu(t("Open documents", "Documentos abiertos")) {
                        ForEach(model.documentWorkspace.documents) { other in
                            Button(URL(fileURLWithPath: other.path).lastPathComponent) { focus(); model.selectWorkspaceTab(other.id) }
                        }
                    }
                }
                Divider()
                Button(t("Split to the right", "Dividir a la derecha")) { focus(); model.splitWorkspace(.horizontal) }
                Button(t("Split below", "Dividir debajo")) { focus(); model.splitWorkspace(.vertical) }
                Button(t("Split above", "Dividir arriba")) { focus(); model.splitWorkspace(.vertical, before: true) }
                Menu(t("Swap with", "Intercambiar con")) {
                    ForEach(model.documentWorkspace.documents.filter { $0.id != document.id && model.documentWorkspace.visibleIDs.contains($0.id) }) { other in
                        Button(URL(fileURLWithPath: other.path).lastPathComponent) { model.documentWorkspace.swap(document.id, other.id) }
                    }
                }
                Divider()
                Button(t("Close pane", "Cerrar panel")) { model.closeWorkspaceTab(document.id) }
        }
    }
    private func focus() { model.selectWorkspaceTab(document.id) }
    private func t(_ en: String, _ es: String) -> String { language == "en" ? en : es }
}

struct DocumentWorkspaceCommands: Commands {
    @ObservedObject var model: Workbench
    var body: some Commands {
        CommandMenu(DocumentWorkspaceText.value("Workspace", "Espacio de trabajo")) {
            Button(DocumentWorkspaceText.value("Split to the right", "Dividir a la derecha")) { model.splitWorkspace(.horizontal) }
                .keyboardShortcut("d", modifiers: [.command]).disabled(model.selectedLibraryPath == nil)
            Button(DocumentWorkspaceText.value("Split below", "Dividir debajo")) { model.splitWorkspace(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.selectedLibraryPath == nil)
            Button(DocumentWorkspaceText.value("Expand or restore pane", "Ampliar o restaurar panel")) {
                if let id = model.documentWorkspace.focusedID { model.expandWorkspacePane(id) }
            }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.selectedLibraryPath == nil || model.documentWorkspace.visibleIDs.count < 2)
            Divider()
            Button(DocumentWorkspaceText.value("Next document", "Documento siguiente")) { model.cycleWorkspaceTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(model.documentWorkspace.documents.isEmpty)
            Button(DocumentWorkspaceText.value("Previous document", "Documento anterior")) { model.cycleWorkspaceTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(model.documentWorkspace.documents.isEmpty)
            Button(DocumentWorkspaceText.value("Close document", "Cerrar documento")) {
                if let id = model.documentWorkspace.focusedID { model.closeWorkspaceTab(id) }
            }.keyboardShortcut("w", modifiers: [.command]).disabled(model.selectedLibraryPath == nil)
        }
    }
}
