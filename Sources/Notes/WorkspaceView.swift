import SwiftUI
import LectureCore

struct WorkbenchView: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var notebookName: String { model.notebooks.first { $0.id == model.selectedNotebookID }?.name ?? "Cuadernos" }

    var body: some View {
        NavigationSplitView {
            CourseSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                    Text(notebookName).lineLimit(1)
                    if let name = model.selectedNote {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        Text(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if model.isDirty { Circle().fill(Color.orange).frame(width: 6, height: 6).help("Sin guardar") }
                    NoteToolbar(model: model)
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
                NoteWorkspace(model: model)
                    .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                        HStack(alignment: .center) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield").help("Todos los cambios se guardan en la copia local")
                                Text("Copia local")
                                if !model.statusText.isEmpty && !model.isDirty { Text("· \(model.statusText)").lineLimit(1) }
                            }.font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            ListeningDock(model: model)
                        }.padding(.horizontal, 24).padding(.vertical, 16)
                            .background(Color(nsColor: .textBackgroundColor))
                    }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.showQuickOpen = true } label: { Label("Buscar notas", systemImage: "magnifyingglass") }
                    .help("Abrir una nota · ⌘P")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            SessionInspector(model: model).inspectorColumnWidth(min: 300, ideal: 340, max: 410)
        }
        .sheet(isPresented: $model.showQuickOpen) { QuickOpenSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.creationKind != nil }, set: { if !$0 { model.creationKind = nil } })) {
            NotebookCreationSheet(model: model, kind: model.creationKind ?? "nota") { model.creationKind = nil }
        }
        .alert("No se aplicó el cambio", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("Cerrar", role: .cancel) { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
    }
}

struct NoteToolbar: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                controls.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                controls.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    .overlay(Capsule().stroke(.separator.opacity(0.6)))
            }
        }.fixedSize().accessibilityElement(children: .contain)
    }
    private var controls: some View {
        HStack(spacing: 12) {
                Picker("Modo de la nota", selection: $model.layout) {
                    Label("Editar", systemImage: "pencil").tag("edit")
                    Label("Ver", systemImage: "doc.richtext").tag("preview")
                }.pickerStyle(.segmented).labelsHidden().labelStyle(.titleAndIcon).frame(width: 150).help("Editar o ver la nota · ⌘E")
                Button { model.saveDraft() } label: { Label("Guardar", systemImage: "square.and.arrow.down") }
                    .disabled(!model.isDirty).help("Guardar la copia · ⌘S")
                Menu {
                    Button("Revisar edición") { model.inspectorHistoryMode = "editor"; model.selectedTab = "changes"; model.showInspector = true }
                        .disabled(!model.isDirty && model.editor?.history.isEmpty != false)
                    Button("Deshacer edición guardada") { model.undoEditor() }
                        .disabled(model.isDirty || model.editor?.history.contains(where: { !$0.undone }) != true)
                    Divider()
                    Button("Nueva nota") { model.creationInitialName = ""; model.creationKind = "nota" }
                    Button("Nueva carpeta") { model.creationInitialName = ""; model.creationKind = "carpeta" }
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                } label: { Label("Opciones de la nota", systemImage: "ellipsis") }.help("Opciones de la nota")
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Mostrar u ocultar inspector · ⌥⌘I")
        }.labelStyle(.iconOnly).buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
    }
}

struct CourseSidebar: View {
    @ObservedObject var model: Workbench
    @State private var query = ""
    @State private var expanded: Set<String> = ["derecho"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notes").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("Tus cuadernos").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.creationInitialName = ""; model.creationKind = "nota" } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 17))
                }.buttonStyle(.plain).help("Nueva nota · ⌘N").accessibilityLabel("Nueva nota")
            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar notas", text: $query).textFieldStyle(.plain).accessibilityLabel("Filtrar archivos")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Limpiar búsqueda") }
            }.padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).padding(12)
            List(selection: Binding(get: { model.selectedNote }, set: { value in if let value, model.notes.contains(value) { model.openNote(value) } })) {
                ForEach(model.notebooks) { notebook in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(notebook.id) || !query.isEmpty }, set: { value in if value { expanded.insert(notebook.id) } else { expanded.remove(notebook.id) } })) {
                        let filenames = model.noteNames(in: notebook).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                        let relativeNames = filenames.map { notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)) }
                        let folders = query.isEmpty ? model.folderNames(in: notebook).map { notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)) } : []
                        ForEach(NotebookNode.tree(notes: relativeNames, folderNames: folders, prefix: notebook.rootPrefix.isEmpty ? "" : notebook.rootPrefix + "/")) { node in
                            CourseTreeRow(model: model, node: node, expandAll: !query.isEmpty) { folder in prepareCreation("nota", folder: folder, notebook: notebook) }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "book.closed.fill").foregroundStyle(Color.accentColor)
                            Text(notebook.name).font(.callout.weight(.semibold)).lineLimit(2)
                            Spacer(minLength: 2)
                            Text("\(model.noteNames(in: notebook).count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                        .contextMenu {
                            Button("Nueva nota") { prepareCreation("nota", folder: notebook.rootPrefix, notebook: notebook) }
                            Button("Nueva carpeta") { prepareCreation("carpeta", folder: notebook.rootPrefix, notebook: notebook) }
                        }
                }
            }.listStyle(.sidebar)
            HStack {
                Menu {
                    Button("Nueva nota") { model.creationInitialName = ""; model.creationKind = "nota" }
                    Button("Nueva carpeta") { model.creationInitialName = ""; model.creationKind = "carpeta" }
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Añadir nota, carpeta o cuaderno").accessibilityLabel("Añadir")
                Spacer()
                Text("\(model.notes.count) notas").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.onChange(of: model.selectedNotebookID) { _, id in expanded.insert(id) }
    }
    private func prepareCreation(_ kind: String, folder: String, notebook: Notebook) {
        model.selectedNotebookID = notebook.id
        let relative = notebook.rootPrefix.isEmpty ? folder : String(folder.dropFirst(notebook.rootPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        model.creationInitialName = relative.isEmpty ? "" : relative + "/"
        model.creationKind = kind
    }
}

struct CourseTreeRow: View {
    @ObservedObject var model: Workbench
    let node: NotebookNode
    var expandAll = false
    var createInFolder: (String) -> Void
    @State private var expanded = false
    var body: some View {
        Group {
            if let children = node.children {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children) { child in CourseTreeRow(model: model, node: child, expandAll: expandAll, createInFolder: createInFolder) }
                } label: {
                    Label(node.name, systemImage: "folder").foregroundStyle(.secondary).font(.callout)
                        .contextMenu { Button("Nueva nota aquí") { createInFolder(node.path) } }
                }
                .onAppear { revealSelection() }
                .onChange(of: model.selectedNote) { _, _ in revealSelection() }
                .onChange(of: expandAll) { _, value in if value { expanded = true } }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: model.selectedNote == node.path ? "doc.text.fill" : "doc.text")
                        .foregroundStyle(model.selectedNote == node.path ? Color.accentColor : .secondary)
                    Text(node.name).font(.callout).lineLimit(2)
                    Spacer(minLength: 2)
                    if model.hasDraft(for: node.path) { Circle().fill(Color.orange).frame(width: 5, height: 5).accessibilityLabel("Sin guardar") }
                }.padding(.vertical, 5).help(node.name).tag(node.path)
                    .contextMenu {
                        Button("Abrir") { model.openNote(node.path) }
                        Button("Editar") { model.openNote(node.path); model.layout = "edit" }
                        Button("Leer") { model.openNote(node.path); model.layout = "preview" }
                        Divider()
                        Button("Sesiones de esta nota") { model.openNote(node.path); model.selectedTab = "library"; model.showInspector = true }
                    }
            }
        }
    }
    private func revealSelection() {
        if expandAll || model.selectedNote?.hasPrefix(node.path + "/") == true { expanded = true }
    }
}

struct NoteWorkspace: View {
    @ObservedObject var model: Workbench
    var body: some View {
        Group {
            if let note = model.selectedNote {
                LiveMarkdownEditor(documentID: note, text: model.draftText, editing: model.layout == "edit", heading: model.previewHeading,
                    onChange: { model.changeDraft($0) }, onLink: { _ = model.openWikilink($0) })
            } else {
                ContentUnavailableView("Abre una nota", systemImage: "doc.text", description: Text("⌘P para buscar"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if model.layout == "split" { model.layout = "edit" } }
        .background {
            Button("") { model.layout = model.layout == "edit" ? "preview" : "edit" }
                .keyboardShortcut("e").hidden().accessibilityHidden(true)
        }
    }
}

struct ListeningDock: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                controls.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                controls.background(Color(nsColor: .controlBackgroundColor), in: Capsule()).overlay(Capsule().stroke(.separator.opacity(0.6)))
            }
        }.fixedSize().accessibilityElement(children: .contain)
    }
    private var controls: some View {
        HStack(spacing: 4) {
            if let media = model.media { MicrophoneButton(model: model, media: media) }
            Divider().frame(height: 20).padding(.horizontal, 2)
            Menu {
                Button { model.selectedTab = "library"; model.showInspector = true } label: { Label("Grabaciones", systemImage: "waveform") }
                Button { model.selectedTab = "replay"; model.showInspector = true } label: { Label("Transcripción", systemImage: "text.bubble") }
                Button { model.selectedTab = "review"; model.showInspector = true } label: { Label("Revisión (\(model.document?.reviews.filter { !$0.resolved }.count ?? 0))", systemImage: "checkmark.bubble") }
                Divider()
                Menu("Versiones") {
                    if model.document?.history.isEmpty != false && model.editor?.history.isEmpty != false {
                        Text("Sin versiones guardadas")
                    }
                    Button("Historial de la sesión") { model.inspectorHistoryMode = "session"; model.selectedTab = "changes"; model.showInspector = true }
                    Button("Historial de edición") { model.inspectorHistoryMode = "editor"; model.selectedTab = "changes"; model.showInspector = true }
                }
                Divider()
                Button("Importar audio o MP4…") { model.importMedia() }
                Button("Crear demo IA inventada (permite retención)") { model.createAIDemo() }
                Button("Iniciar/detener demo sintética") { model.toggleDemo() }
                Button("Nueva sesión sintética") { model.perform { try model.createSession() }; model.selectedTab = "replay"; model.showInspector = true }.disabled(model.busy)
            } label: { Image(systemName: "waveform").frame(width: 34, height: 32) }
                .menuStyle(.borderlessButton).fixedSize().help("Grabaciones, transcripción y versiones").accessibilityLabel("Grabaciones y versiones")
        }.padding(6)
    }
}

struct QuickOpenSheet: View {
    @ObservedObject var model: Workbench
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    private var matches: [String] { model.notes.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Abrir una nota…", text: $query).textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { open(selection ?? matches.first) }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                Button { model.showQuickOpen = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cerrar · Esc")
            }.padding(20)
            Divider()
            if matches.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 180)
            } else {
                List(selection: $selection) {
                    ForEach(matches, id: \.self) { name in
                        Button { open(name) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent).lineLimit(1)
                                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if name == model.selectedNote { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain).tag(name)
                    }
                }.listStyle(.plain).frame(height: 280)
            }
            HStack { Text("↵ abrir"); Spacer(); Text("esc cerrar") }.font(.caption).foregroundStyle(.secondary).padding(14)
        }.frame(width: 580)
            .onAppear { focused = true; selection = matches.first }
            .onChange(of: query) { _, _ in selection = matches.first }
            .onExitCommand { model.showQuickOpen = false }
    }
    private func open(_ name: String?) { if let name { model.openNote(name); model.showQuickOpen = false } }
    private func moveSelection(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let index = selection.flatMap { matches.firstIndex(of: $0) } ?? 0
        selection = matches[max(0, min(matches.count - 1, index + offset))]
    }
}

struct NotebookCreationSheet: View {
    @ObservedObject var model: Workbench
    let kind: String
    var close: () -> Void
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(kind == "cuaderno" ? "Nuevo cuaderno" : kind == "carpeta" ? "Nueva carpeta" : "Nueva nota").font(.title2.bold())
            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Text("Copia local").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Crear") {
                    do { try model.createNotebookItem(kind: kind, name: name); close(); model.layout = "edit" }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440).onAppear { name = model.creationInitialName; focused = true }
    }
}

struct MicrophoneButton: View {
    @ObservedObject var model: Workbench
    @ObservedObject var media: MediaController
    var body: some View {
        Button { model.toggleMicrophone() } label: {
            HStack(spacing: 8) { Image(systemName: media.isRecording ? "stop.fill" : "mic.fill"); Text(media.isRecording ? "Grabando · Detener" : "Grabar").font(.callout.weight(.medium)) }.padding(.horizontal, 12).padding(.vertical, 8)
        }.buttonStyle(.plain).foregroundStyle(media.isRecording ? Color.red : Color.primary).disabled(media.busy || model.busy).help(media.isRecording ? "Detener grabación local" : "Iniciar micrófono · solo al pulsar este botón")
    }
}
