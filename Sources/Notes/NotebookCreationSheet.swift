import SwiftUI
import LectureCore

struct NotebookCreationSheet: View {
    @ObservedObject var model: Workbench
    let kind: String
    var close: () -> Void
    @State private var name: String
    @State private var notebookID: String
    @State private var folder: String
    @State private var error: String?
    @FocusState private var focused: Bool
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""

    init(model: Workbench, kind: String, close: @escaping () -> Void) {
        self.model = model; self.kind = kind; self.close = close
        let notebook = model.currentNotebook
        let initial = model.creationInitialName
        let initialFolder: String
        if initial.hasSuffix("/") {
            initialFolder = (notebook.rootPrefix.isEmpty ? "" : notebook.rootPrefix + "/") + String(initial.dropLast())
        } else {
            initialFolder = model.selectedFolder ?? model.selectedLibraryPath.map {
                $0.components(separatedBy: "/").dropLast().joined(separator: "/")
            } ?? notebook.rootPrefix
        }
        _name = State(initialValue: initial.hasSuffix("/") ? "" : initial)
        _notebookID = State(initialValue: notebook.id)
        _folder = State(initialValue: model.folderNames(in: notebook).contains(initialFolder) ? initialFolder : notebook.rootPrefix)
    }
    private func t(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var notebook: Notebook? { model.activeNotebooks.first { $0.id == notebookID } }
    private var title: String {
        kind == "cuaderno" ? t("Nuevo cuaderno", "New notebook") : kind == "carpeta" ? t("Nueva carpeta", "New folder") : t("Nueva nota", "New note")
    }
    private var folders: [AIOption] {
        guard let notebook else { return [] }
        return [.init(id: notebook.rootPrefix, title: t("Raíz del cuaderno", "Notebook root"))] + model.folderNames(in: notebook).sorted().map {
            .init(id: $0, title: notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)))
        }
    }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (kind == "cuaderno" || (notebook != nil && folders.contains { $0.id == folder }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32)
                        .modifier(NotebookGlassCloseSurface())
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(t("Cerrar", "Close"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Nombre", "Name")).font(.callout.weight(.medium))
                HStack(spacing: 9) {
                    Image(systemName: kind == "cuaderno" ? "book.closed" : kind == "carpeta" ? "folder" : "doc.text").foregroundStyle(.secondary)
                    TextField(t("Nombre", "Name"), text: $name).textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                        .onSubmit { create() }.accessibilityIdentifier("notebook.creation.name")
                }.padding(12).modifier(NotebookInputSurface(radius: 12))
            }
            if kind != "cuaderno" {
                VStack(alignment: .leading, spacing: 12) {
                    location(t("Cuaderno", "Notebook"), symbol: "book.closed", options: model.activeNotebooks.map { .init(id: $0.id, title: $0.name) }, selection: $notebookID, id: "notebook.creation.notebook")
                    if let notebook {
                        CreationFolderBrowser(notebook: notebook, options: folders, selection: $folder)
                            .accessibilityIdentifier("notebook.creation.folder")
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).accessibilityIdentifier("notebook.creation.error") }
            HStack {
                Spacer()
                Button(t("Cancelar", "Cancel"), action: close).buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                Button(action: create) {
                    Text(t("Crear", "Create")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(NotebookAccent.color(accent), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.45).accessibilityIdentifier("notebook.creation.create")
            }
        }.padding(24).frame(width: 460)
            .onAppear {
                focused = true
                do { try model.refreshCreationLocations() } catch { self.error = error.localizedDescription }
            }
            .onChange(of: notebookID) { _, _ in folder = notebook?.rootPrefix ?? ""; error = nil }
            .onChange(of: name) { _, _ in error = nil }
            .onChange(of: folder) { _, _ in error = nil }
    }
    private func location(_ title: String, symbol: String, options: [AIOption], selection: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            CreationLocationSelector(title: title, symbol: symbol, options: options, selection: selection)
                .accessibilityIdentifier(id)
        }
    }
    private func create() {
        guard canCreate else { return }
        do {
            try model.createNotebookItem(kind: kind, name: name, notebookID: notebookID, folder: kind == "cuaderno" ? nil : folder)
            if kind == "nota" { model.layout = "edit" }
            model.notebookRevealRequest += 1
            close()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CreationFolderBrowser: View {
    let notebook: Notebook
    let options: [AIOption]
    @Binding var selection: String
    @State private var search = ""
    @State private var hovered: String?
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private var root: String { notebook.rootPrefix }
    private var relative: String { selection == root ? "" : root.isEmpty ? selection : String(selection.dropFirst(root.count + 1)) }
    private var children: [AIOption] {
        options.filter { item in
            guard item.id != root else { return false }
            return search.isEmpty
                ? item.id.components(separatedBy: "/").dropLast().joined(separator: "/") == selection
                : item.title.localizedCaseInsensitiveContains(search)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selection = selection.components(separatedBy: "/").dropLast().joined(separator: "/")
                    search = ""
                } label: { Image(systemName: "arrow.left").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).modifier(ControlHoverBackground()).disabled(selection == root)
                    .accessibilityLabel(language == "en" ? "Parent folder" : "Carpeta superior")
                    .accessibilityIdentifier("notebook.creation.parentFolder")
                Button { selection = root; search = "" } label: { Image(systemName: "book.closed"); Text(notebook.name).lineLimit(1) }
                    .buttonStyle(.plain).foregroundStyle(NotebookAccent.color(accent))
                    .accessibilityIdentifier("notebook.creation.rootFolder")
                if !relative.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(relative).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.font(.callout).padding(10)
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(language == "en" ? "Search folders…" : "Buscar carpetas…", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("notebook.creation.searchFolders")
            }.padding(12).font(.callout)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(children) { item in
                        Button { selection = item.id; search = "" } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(NotebookAccent.color(accent)).frame(width: 22)
                                Text(search.isEmpty ? item.id.components(separatedBy: "/").last ?? item.title : item.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                            }.font(.callout).padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
                                .background(hovered == item.id ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).onHover { hovered = $0 ? item.id : nil }
                            .accessibilityIdentifier("notebook.creation.enterFolder." + item.id)
                    }
                    if children.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: search.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                            Text(language == "en" ? (search.isEmpty ? "No subfolders here" : "No matching folders") : (search.isEmpty ? "No hay subcarpetas aquí" : "No hay carpetas coincidentes")).font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                }.padding(.horizontal, 6)
            }.frame(height: 160)
            Divider().opacity(0.5)
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(NotebookAccent.color(accent))
                Text(language == "en" ? "Create in: " : "Crear en: ") + Text(relative.isEmpty ? notebook.name : notebook.name + " / " + relative)
            }.font(.caption).lineLimit(2).padding(12)
        }.modifier(NotebookInputSurface(radius: 12))
            .onChange(of: notebook.id) { _, _ in search = "" }
    }
}

struct LibraryRenameSheet: View {
    @ObservedObject var model: Workbench
    let item: NotebookSidebarSelection
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    init(model: Workbench, item: NotebookSidebarSelection) {
        self.model = model; self.item = item
        switch item {
        case .notebook(let id): _name = State(initialValue: model.notebooks.first { $0.id == id }?.name ?? "")
        case .folder(let path): _name = State(initialValue: (path as NSString).lastPathComponent)
        case .note(let path): _name = State(initialValue: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
    }
    private var symbol: String {
        switch item { case .notebook: return "book.closed"; case .folder: return "folder"; case .note: return "doc.text" }
    }
    private var title: String {
        switch item {
        case .notebook: return language == "en" ? "Rename notebook" : "Renombrar cuaderno"
        case .folder: return language == "en" ? "Rename folder" : "Renombrar carpeta"
        case .note: return language == "en" ? "Rename document" : "Renombrar documento"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(NotebookAccent.color(accent))
                TextField(language == "en" ? "Name" : "Nombre", text: $name).textFieldStyle(.plain).focused($focused).onSubmit(rename)
                    .accessibilityIdentifier("notebook.rename.name")
            }.padding(12).modifier(NotebookInputSurface(radius: 12))
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(language == "en" ? "Cancel" : "Cancelar") { model.renamingItem = nil }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Button(action: rename) {
                    Text(language == "en" ? "Rename" : "Renombrar").font(.callout.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(NotebookAccent.color(accent), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("notebook.rename.save")
            }
        }.padding(24).frame(width: 420).onAppear { focused = true }
    }
    private func rename() {
        do {
            switch item {
            case .notebook(let id): try model.renameNotebook(id, name: name)
            case .folder(let path): try model.renameLibraryFolder(path, name: name)
            case .note(let path): try model.renameLibraryFile(path, name: name)
            }
            model.renamingItem = nil
        }
        catch { self.error = error.localizedDescription }
    }
}

private struct CreationLocationSelector: View {
    let title: String
    let symbol: String
    let options: [AIOption]
    @Binding var selection: String
    @State private var presented = false
    @State private var search = ""
    @State private var hovered: String?
    @AppStorage("notes.language") private var language = "es"
    private var matches: [AIOption] { options.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        Button {
            search = ""
            presented = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(options.first { $0.id == selection }?.title ?? "—").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 14)).padding(12).contentShape(Rectangle())
                .modifier(NotebookInputSurface(radius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(options.first { $0.id == selection }?.title ?? "")
            .disabled(options.isEmpty)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                notebookList.frame(width: 330).background(Color(nsColor: .windowBackgroundColor))
                    .onExitCommand { presented = false }
            }
    }
    private var searchInput: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(language == "en" ? "Search…" : "Buscar…", text: $search).textFieldStyle(.plain)
        }.padding(9)
    }
    private var notebookList: some View {
        VStack(spacing: 4) {
            searchInput
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(matches) { option in
                        Button { selection = option.id; presented = false } label: {
                            HStack(spacing: 8) {
                                Text(option.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                if selection == option.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                            }.font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .modifier(SelectorRowBackground(highlighted: selection == option.id || hovered == option.id))
                        }.buttonStyle(.plain).onHover { hovered = $0 ? option.id : nil }
                            .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                    }
                    if matches.isEmpty { Text(language == "en" ? "No results" : "Sin resultados").font(.callout).foregroundStyle(.secondary).padding(8) }
                }
            }.frame(height: min(250, CGFloat(max(1, matches.count)) * 38))
        }.padding(5)
    }
}
