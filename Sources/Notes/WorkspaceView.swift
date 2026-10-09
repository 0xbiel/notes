import SwiftUI
import LectureCore
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var notebookName: String { model.notebooks.first { $0.id == model.selectedNotebookID }?.name ?? "Cuadernos" }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chrome = CompactChrome()
    @AppStorage("notes.language") private var language = "es"

    @State private var preferencesSection: NotebookPreferencesSection = .general

    private let sidebarWidth = CompactLayout.sidebarWidth

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: chrome.compact ? 0 : sidebarWidth)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        noteLocation
                        Spacer(minLength: 8)
                        if let path = model.selectedNote ?? model.selectedFile {
                            DocumentFileActions(model: model, path: path)
                        }
                        if model.selectedNote != nil { NoteToolbar(model: model) }
                    }
                    .padding(.horizontal, 18).frame(height: 58)
                    .background(WindowDragRegion())
                    Divider().opacity(0.4)
                    HStack(spacing: 0) {
                        NoteWorkspace(model: model)
                        if model.showInspector {
                            Divider()
                            SessionInspector(model: model).frame(width: 320)
                        }
                    }
                    if model.assistant == nil || (model.selectedNote != nil && model.layout == "preview" && model.hideStudyComposer && model.media?.isRecording == true) {
                        HStack { Spacer(); ListeningDock(model: model) }.padding(12)
                    }
                }
                .opacity(model.showPreferences ? 0 : 1)
                .allowsHitTesting(!model.showPreferences)
                .accessibilityHidden(model.showPreferences)
                .overlay {
                    if model.showPreferences { NotebookPreferences(model: model, section: $preferencesSection) }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.25)))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .padding(8)
                .overlay(alignment: .top) {
                    if !model.chatHistoryVisible, let media = model.media, let assistant = model.assistant, let ai = model.ai {
                        NotebookStatusIndicator(media: media, assistant: assistant, ai: ai).padding(.top, 17)
                    }
                }
            }
            library
                .padding(.horizontal, chrome.compact ? 4 : 0)
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .background { if chrome.compact { NotebookThemeBackground() } }
                .clipShape(RoundedRectangle(cornerRadius: chrome.compact ? CompactLayout.sidebarRadius : 0))
                .overlay {
                    if chrome.compact {
                        RoundedRectangle(cornerRadius: CompactLayout.sidebarRadius)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(chrome.compact ? 0.18 : 0), radius: 14, x: 4)
                .padding(.horizontal, chrome.compact ? CompactLayout.horizontalInset : 0)
                .padding(.vertical, chrome.compact ? CompactLayout.verticalInset : 0)
                .opacity(chrome.sidebarVisible ? 1 : 0)
                .offset(x: chrome.sidebarVisible ? 0 : -sidebarWidth)
                .allowsHitTesting(chrome.sidebarVisible)
                .accessibilityHidden(!chrome.sidebarVisible)

        }
        .tint(.gray).accentColor(.gray)
        .background(NotebookAccentCaret())
        .environment(\.locale, Locale(identifier: language))
        .background(NotebookThemeBackground(blendsBehindWindow: true))
        .background(CompactWindowBridge(chrome: chrome, modalPresented: model.showQuickOpen || model.creationKind != nil || model.errorText != nil || model.showNotebookManagement))
        .focusedSceneObject(chrome)
        .onGeometryChange(for: Bool.self) { $0.size.width < 900 } action: { narrow in
            if narrow && !chrome.compact { chrome.toggleCompact() }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chrome.compact)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chrome.sidebarVisible)
        .onChange(of: model.showPreferences) { _, presented in
            if presented { preferencesSection = .general }
        }
        .sheet(isPresented: $model.showNotebookManagement) {
            if let assistant = model.assistant { NotebookManagement(model: model, assistant: assistant, notebook: model.currentNotebook) }
        }
        .sheet(isPresented: $model.showQuickOpen) { QuickOpenSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.creationKind != nil }, set: { if !$0 { model.creationKind = nil } })) {
            NotebookCreationSheet(model: model, kind: model.creationKind ?? "nota") { model.creationKind = nil }
        }
        .alert("No se aplicó el cambio", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("Cerrar", role: .cancel) { model.errorText = nil }
        } message: { Text(NotebookAssistantText.display(model.errorText ?? "", language: language)) }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                NativeWindowControls(chrome: chrome).frame(width: 76, height: 34)
                Spacer()
                Button { chrome.toggleCompact() } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .modifier(ControlHoverBackground())
                    .help(chrome.compact ? "Salir del modo compacto · ⌥⌘C" : "Modo compacto · ⌥⌘C")
                    .accessibilityLabel(chrome.compact ? "Salir del modo compacto" : "Alternar modo compacto")
            }.padding(.horizontal, 18).frame(height: chrome.compact ? 50 : 58)
                .background(WindowDragRegion())
            if model.showPreferences {
                NotebookPreferencesSidebar(section: $preferencesSection, compact: chrome.compact) { model.showPreferences = false }
            } else {
                CourseSidebar(model: model)
            }
        }
    }

    private var noteLocation: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.selectedLibraryPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? notebookName)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            if model.selectedLibraryPath != nil { Text(notebookName).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(minWidth: 100, alignment: .leading)
    }

}

struct DocumentFileActions: View {
    @ObservedObject var model: Workbench
    let path: String
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        HStack(spacing: 14) {
            Button {
                if path == model.selectedNote { model.flushAutosave(); guard !model.isDirty else { return } }
                if let url = try? model.workspace?.fileURL(path) { NSWorkspace.shared.open(url) }
            } label: {
                Label(language == "en" ? "Open" : "Abrir", systemImage: "arrow.up.forward.app")
            }.help(language == "en" ? "Open in the default app" : "Abrir en la aplicación predeterminada")
                .accessibilityIdentifier("document.openExternal")
            Button {
                if let url = try? model.workspace?.fileURL(path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Label(language == "en" ? "Show in Finder" : "Mostrar en Finder", systemImage: "folder")
            }.accessibilityIdentifier("document.showInFinder")
        }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).fixedSize()
    }
}

struct NoteToolbar: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation
    var body: some View {
        controls.fixedSize().accessibilityElement(children: .contain)
    }
    private var modeSelector: some View {
        HStack(spacing: 2) {
            modeButton("Editar", value: "edit")
            modeButton("Ver", value: "preview")
        }.padding(4)
            .background(.primary.opacity(0.045), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Modo de la nota")
            .help("Editar o ver la nota · ⌘E")
    }
    private func modeButton(_ title: String, value: String) -> some View {
        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.layout = value } } label: {
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: model.layout == value ? .semibold : .regular))
                .foregroundStyle(model.layout == value ? .primary : .secondary)
                .frame(width: 64, height: 30)
                .background {
                    if model.layout == value {
                        if #available(macOS 26.0, *), !reduceTransparency {
                            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: .capsule)
                                .matchedGeometryEffect(id: "note-mode", in: selectionAnimation)
                        } else {
                            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(Capsule().stroke(.separator.opacity(0.5)))
                        }
                    }
                }
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(model.layout == value ? .isSelected : [])
    }
    private var controls: some View {
        HStack(spacing: 7) {
                modeSelector
                if model.layout == "preview" {
                    Button { model.hideStudyComposer.toggle() } label: { Image(systemName: model.hideStudyComposer ? "bubble.left" : "bubble.left.fill").frame(width: 26, height: 26) }
                        .modifier(ControlHoverBackground()).help(model.hideStudyComposer ? "Mostrar asistente" : "Ocultar asistente")
                        .accessibilityLabel(model.hideStudyComposer ? "Mostrar asistente" : "Ocultar asistente").accessibilityIdentifier("notebook.toggleAssistant")
                }
                Menu {
                        Button("Marcar/desmarcar tarea") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownTask(_:)), to: nil, from: nil) }.keyboardShortcut("l", modifiers: [.command, .shift])
                    Section("Formato") {
                        Button("Negrita") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownBold(_:)), to: nil, from: nil) }.keyboardShortcut("b")
                        Button("Cursiva") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownItalic(_:)), to: nil, from: nil) }.keyboardShortcut("i")
                        Button("Código en línea") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownCode(_:)), to: nil, from: nil) }.keyboardShortcut("k", modifiers: [.command, .shift])
                    }.disabled(model.layout != "edit" || model.selectedNote == nil)
                    Button("Insertar tabla…") { NSApp.sendAction(#selector(MarkdownTextView.insertMarkdownTable(_:)), to: nil, from: nil) }.disabled(model.layout != "edit" || model.selectedNote == nil)
                    Divider()
                    Button("Revisar edición") { model.inspectorHistoryMode = "editor"; model.selectedTab = "changes"; model.showInspector = true }
                        .disabled(!model.isDirty && model.editor?.history.isEmpty != false)
                    Button("Deshacer edición guardada") { model.undoEditor() }
                        .disabled(model.isDirty || model.editor?.history.contains(where: { !$0.undone && $0.superseded != true }) != true)
                    Divider()
                    Button("Nueva nota") { model.creationInitialName = ""; model.creationKind = "nota" }
                    Button("Nueva carpeta") { model.creationInitialName = ""; model.creationKind = "carpeta" }
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                } label: { Label("Opciones de la nota", systemImage: "ellipsis").frame(width: 26, height: 26) }.modifier(ControlHoverBackground()).help("Opciones de la nota")
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right").frame(width: 26, height: 26) }
                    .modifier(ControlHoverBackground()).help("Mostrar u ocultar inspector · ⌥⌘I")
        }.labelStyle(.iconOnly).buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
    }
}

enum NotebookSidebarSelection: Hashable { case notebook(String), note(String), folder(String) }

struct CourseSidebar: View {
    @ObservedObject var model: Workbench
    @State private var query = ""
    @State private var section = LibraryContentFilter.notes
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var expanded: Set<String> = ["derecho"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar", text: $query).textFieldStyle(.plain).accessibilityLabel("Filtrar archivos")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).modifier(ControlHoverBackground()).help("Limpiar búsqueda")
                    }
                }.padding(.horizontal, 11).frame(height: 34)
                    .modifier(SidebarSearchGlass())
                filterMenu
                Button { model.creationInitialName = ""; model.creationKind = "nota" } label: {
                    Image(systemName: "square.and.pencil").frame(width: 28, height: 34)
                }.buttonStyle(.plain).modifier(ControlHoverBackground()).help("Nueva nota · ⌘N").accessibilityLabel("Nueva nota")
            }.padding(.horizontal, 12)
            if section != .notes, let media = model.media {
                RecordingSidebar(model: model, media: media, query: query, filter: section)
            } else {
            List(selection: Binding<NotebookSidebarSelection?>(get: {
                model.librarySelection
            }, set: { value in
                switch value {
                case .notebook(let id): model.openNotebook(id)
                case .note(let path): if model.libraryFiles.contains(path) { model.openLibraryFile(path) }
                case .folder(let path): model.selectLibraryFolder(path)
                case nil: break
                }
            })) {
                ForEach(model.activeNotebooks) { notebook in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(notebook.id) || !query.isEmpty }, set: { value in if value { expanded.insert(notebook.id) } else { expanded.remove(notebook.id) } })) {
                        let filenames = model.fileNames(in: notebook).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                        let relativeNames = filenames.map { notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)) }
                        let folders = query.isEmpty ? model.folderNames(in: notebook).map { notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)) } : []
                        ForEach(NotebookNode.tree(notes: relativeNames, folderNames: folders, prefix: notebook.rootPrefix.isEmpty ? "" : notebook.rootPrefix + "/")) { node in
                            CourseTreeRow(model: model, node: node, expandAll: !query.isEmpty) { folder in prepareCreation("nota", folder: folder, notebook: notebook) }
                        }
                    } label: {
                        Button { model.openNotebook(notebook.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "book.closed.fill").foregroundStyle(.secondary)
                                Text(notebook.name).font(.callout.weight(.semibold)).lineLimit(2)
                                Spacer(minLength: 2)
                                Text("\(model.fileNames(in: notebook).count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).padding(.horizontal, 2).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("notebook.open." + notebook.id)
                            .accessibilityAddTraits(model.selectedNotebookID == notebook.id && model.selectedLibraryPath == nil ? .isSelected : [])
                        .contextMenu {
                            Button("Nueva nota") { prepareCreation("nota", folder: notebook.rootPrefix, notebook: notebook) }
                            Button("Nueva carpeta") { prepareCreation("carpeta", folder: notebook.rootPrefix, notebook: notebook) }
                            Button("Importar archivos…") { model.chooseLibraryImport(into: notebook.rootPrefix, notebookID: notebook.id) }.disabled(!model.canManageFiles)
                            Divider()
                            Button("Copiar cuaderno") { model.copyLibraryItem(.notebook(notebook.id)) }.disabled(!model.canManageFiles)
                            Button("Pegar") { model.pasteLibraryItems(into: notebook.rootPrefix, notebookID: notebook.id) }.disabled(!model.canManageFiles)
                            Divider()
                            Button("Eliminar cuaderno", role: .destructive) { model.deleteNotebook(notebook) }.disabled(!model.canManageFiles)
                        }
                    }
                    .tag(NotebookSidebarSelection.notebook(notebook.id))
                    .dropDestination(for: URL.self) { urls, _ in
                        guard model.canManageFiles, !urls.isEmpty else { return false }
                        model.importLibraryFiles(urls, into: notebook.rootPrefix, notebookID: notebook.id); return true
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).background(NeutralSidebarSelection())
                .contextMenu {
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                    Button("Pegar") { model.pasteLibraryItems(into: model.libraryDestination, notebookID: model.currentNotebook.id) }.disabled(!model.canManageFiles)
                }
            }
            HStack {
                Menu {
                    Button("Nueva nota") { model.creationInitialName = ""; model.creationKind = "nota" }
                    Button("Nueva carpeta") { model.creationInitialName = ""; model.creationKind = "carpeta" }
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                    Divider()
                    Button("Importar archivos…") { model.chooseLibraryImport(into: model.libraryDestination, notebookID: model.currentNotebook.id) }.disabled(!model.canManageFiles || model.activeNotebooks.isEmpty)
                } label: { Image(systemName: "plus").frame(width: 28, height: 34).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Añadir nota, carpeta o cuaderno").accessibilityLabel("Añadir")
                Button { model.showPreferences = true } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }.buttonStyle(.plain).modifier(ControlHoverBackground()).help("Preferencias · ⌘,").accessibilityLabel("Preferencias")
                Spacer()
                NotebookTrashMenu(model: model)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(NotebookLibraryClipboard(model: model))
            .contextMenu { Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" } }
            .onChange(of: model.selectedNotebookID) { _, id in expanded.insert(id) }

    }
    private var filterMenu: some View {
        Menu {
            ForEach(LibraryContentFilter.allCases) { filter in
                Button { section = filter } label: {
                    Label(LocalizedStringKey(filter.title), systemImage: filter.symbol)
                }
                .accessibilityAddTraits(section == filter ? .isSelected : [])
            }
        } label: {
            Image(systemName: section.symbol)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 34, height: 34)
            .modifier(ControlHoverBackground())
            .accessibilityLabel("Filtrar por tipo: \(section.title)")
            .help("Texto, audio o vídeos importados")
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
                        .contextMenu {
                            Button("Nueva nota aquí") { createInFolder(node.path) }
                            Button("Nueva carpeta aquí") { model.createFolderInside(node.path) }
                            Button("Importar archivos…") { if let owner = model.projects?.owner(of: node.path + "/placeholder") { model.chooseLibraryImport(into: node.path, notebookID: owner.id) } }.disabled(!model.canManageFiles)
                            Divider()
                            Button("Copiar carpeta") { model.copyLibraryItem(.folder(node.path)) }.disabled(!model.canManageFiles)
                            Button("Pegar") { if let owner = model.projects?.owner(of: node.path + "/placeholder") { model.pasteLibraryItems(into: node.path, notebookID: owner.id) } }.disabled(!model.canManageFiles)
                            LibraryMoveMenu(model: model, path: node.path, folder: true)
                            Divider()
                            Button("Eliminar carpeta", role: .destructive) { model.deleteItem(node.path, folder: true) }.disabled(!model.canManageFiles)
                        }
                }
                .tag(NotebookSidebarSelection.folder(node.path))
                .dropDestination(for: URL.self) { urls, _ in
                    guard model.canManageFiles, !urls.isEmpty, let owner = model.projects?.owner(of: node.path + "/placeholder") else { return false }
                    model.importLibraryFiles(urls, into: node.path, notebookID: owner.id); return true
                }
                .onAppear { revealSelection() }
                .onChange(of: model.selectedLibraryPath) { _, _ in revealSelection() }
                .onChange(of: expandAll) { _, value in if value { expanded = true } }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: LibraryFileIcon.symbol(node.path))
                        .foregroundStyle(model.selectedLibraryPath == node.path ? .primary : .secondary)
                    Text(node.name).font(.callout).lineLimit(2)
                    Spacer(minLength: 2)
                    if model.hasDraft(for: node.path) { Circle().fill(Color.orange).frame(width: 5, height: 5).accessibilityLabel("Sin guardar") }
                }.padding(.vertical, 6).padding(.horizontal, 2)
                    .help(node.name).tag(NotebookSidebarSelection.note(node.path))
                    .contextMenu {
                        Button("Abrir") { model.openLibraryFile(node.path) }
                        if node.path.hasSuffix(".md") {
                            Button("Editar") { model.openNote(node.path); model.layout = "edit" }
                            Button("Ver") { model.openNote(node.path); model.layout = "preview" }
                            Button("Sesiones de esta nota") { model.openNote(node.path); model.selectedTab = "library"; model.showInspector = true }
                        }
                        Divider()
                        Button("Copiar archivo") { model.copyLibraryItem(.note(node.path)) }.disabled(!model.canManageFiles)
                        LibraryMoveMenu(model: model, path: node.path, folder: false)
                        Divider()
                        Button("Eliminar documento", role: .destructive) { model.deleteItem(node.path, folder: false) }.disabled(!model.canManageFiles)
                    }
            }
        }
    }
    private func revealSelection() {
        if expandAll || model.selectedLibraryPath?.hasPrefix(node.path + "/") == true { expanded = true }
    }
}

struct NoteWorkspace: View {
    @ObservedObject var model: Workbench
    @State private var composerHeight: CGFloat = 130
    private var showsComposer: Bool { model.selectedNote != nil && model.assistant != nil && (model.layout != "preview" || !model.hideStudyComposer) }
    var body: some View {
        Group {
            if model.activeNotebooks.isEmpty {
                ContentUnavailableView {
                    Label("Sin cuadernos", systemImage: "book.closed")
                } actions: {
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                }
            } else if let file = model.selectedFile, let workspace = model.workspace {
                NotebookFilePreview(workspace: workspace, path: file)
            } else if let note = model.selectedNote {
                LiveMarkdownEditor(documentID: note, text: model.draftText, editing: model.layout == "edit", heading: model.previewHeading,
                    bottomInset: showsComposer ? composerHeight : 0,
                    onChange: { model.changeDraft($0) }, onLink: { _ = model.openWikilink($0) }, onTaskToggle: { _ in if model.layout == "preview" { model.saveDraft() } })
            } else {
                if let assistant = model.assistant { NotebookHome(model: model, assistant: assistant) }
                else { ContentUnavailableView("Abre una nota", systemImage: "doc.text", description: Text("⌘P para buscar")) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if showsComposer, let assistant = model.assistant {
                NotebookComposer(model: model, assistant: assistant).frame(maxWidth: 740)
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        .onAppear { if model.layout == "split" { model.layout = "edit" } }
        .background {
            Button("") { model.layout = model.layout == "edit" ? "preview" : "edit" }
                .keyboardShortcut("e").hidden().accessibilityHidden(true)
        }
    }
}

struct ListeningDock: View {
    @ObservedObject var model: Workbench
    var embedded = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if embedded { controls }
            else if #available(macOS 26.0, *), !reduceTransparency {
                controls.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                controls.background(Color(nsColor: .controlBackgroundColor), in: Capsule()).overlay(Capsule().stroke(.separator.opacity(0.6)))
            }
        }.fixedSize().accessibilityElement(children: .contain)
    }
    private var controls: some View {
        HStack(spacing: 4) {
            Button { model.notebookCheckpointSelection = nil; model.showNotebookManagement = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 30, height: 32) }
                .buttonStyle(.plain).help("Gestionar cuaderno").accessibilityLabel("Gestionar cuaderno").accessibilityIdentifier("notebook.manage")
            if let media = model.media { MicrophoneButton(model: model, media: media, compact: embedded) }
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
            } label: {
                if let media = model.media { RecordingMenuIcon(media: media) }
                else { Image(systemName: "waveform").foregroundStyle(.secondary).frame(width: 34, height: 32) }
            }
                .menuStyle(.borderlessButton).fixedSize().help("Grabaciones, transcripción y versiones").accessibilityLabel("Grabaciones y versiones")
        }.padding(embedded ? 0 : 6)
    }
}

struct QuickOpenSheet: View {
    @ObservedObject var model: Workbench
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    private let preferencesAction = "notes-action://preferences"
    private var matches: [String] {
        let notes = model.libraryFiles.filter { model.projects?.owner(of: $0)?.archivedAt == nil && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
        let showPreferences = query.isEmpty || ["Preferences", "Settings", "Preferencias", "Ajustes", "Theme", "Tema"].contains { $0.localizedCaseInsensitiveContains(query) }
        return notes + (showPreferences ? [preferencesAction] : [])
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Abrir nota o preferencias…", text: $query).textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { open(selection ?? matches.first) }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                Button { model.showQuickOpen = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).modifier(ControlHoverBackground()).help("Cerrar · Esc")
            }.padding(20)
            Divider()
            if matches.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 180)
            } else {
                List(selection: $selection) {
                    ForEach(matches, id: \.self) { name in
                        Button { open(name) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: name == preferencesAction ? "gearshape" : "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    if name == preferencesAction {
                                        Text("Preferencias")
                                        Text("General y tema").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent).lineLimit(1)
                                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
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
    private func open(_ name: String?) {
        guard let name else { return }
        model.showQuickOpen = false
        if name == preferencesAction { model.showPreferences = true }
        else { model.showPreferences = false; model.openLibraryFile(name) }
    }
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
    var compact = false
    var body: some View {
        Button { model.toggleMicrophone() } label: {
            HStack(spacing: 8) { Image(systemName: media.isRecording ? "stop.fill" : "mic.fill"); if !compact { Text(media.isRecording ? "Grabando · Detener" : "Grabar").font(.callout.weight(.medium)) } }.padding(.horizontal, 12).padding(.vertical, 8)
        }.accessibilityLabel(media.isRecording ? "Detener grabación" : "Grabar y transcribir").buttonStyle(.plain).foregroundStyle(media.isRecording ? Color.red : Color.primary).disabled(!media.isRecording && (media.busy || model.busy)).help(media.isRecording ? "Detener grabación local" : "Iniciar micrófono · solo al pulsar este botón")
    }
}

/// Status comes only from existing local job metadata; no quality score is inferred.
struct RecordingPresentation {
    let job: MediaJob
    var needsReview: Bool { job.asrQualityWarning != nil || job.transcript.contains { $0.boundaryReview == true } }
    var title: String {
        if [.failed, .interrupted, .cancelled].contains(job.stage) { return job.stage.label }
        if [.recording, .copying, .extracting, .transcribing].contains(job.stage) { return job.stage.label }
        if needsReview { return "Por revisar" }
        if job.transcript.isEmpty { return "Sin transcripción" }
        return "Transcripción disponible"
    }
    var symbol: String {
        if job.stage == .recording { return "record.circle" }
        if [.failed, .interrupted, .cancelled].contains(job.stage) || needsReview { return "exclamationmark.circle" }
        return job.transcript.isEmpty ? "waveform" : "text.alignleft"
    }
    var color: Color {
        if job.stage == .recording || job.stage == .failed { return .red }
        if needsReview || [.interrupted, .cancelled].contains(job.stage) { return .orange }
        return .secondary
    }
    var detail: String { job.asrQualityWarning ?? job.error ?? title }
}

enum LibraryContentFilter: String, CaseIterable, Identifiable {
    case notes, audio, video
    var id: Self { self }
    var title: String {
        switch self { case .notes: "Texto"; case .audio: "Audio"; case .video: "Vídeo" }
    }
    var symbol: String {
        switch self { case .notes: "doc.text"; case .audio: "waveform"; case .video: "film" }
    }
    func includes(_ job: MediaJob) -> Bool {
        let ext = URL(fileURLWithPath: job.sourceName).pathExtension.lowercased()
        let isVideo = !job.isMicrophone && (UTType(filenameExtension: ext)?.conforms(to: .movie) == true
            || ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(ext))
        switch self {
        case .notes: return false
        case .audio: return !isVideo
        case .video: return isVideo
        }
    }
}

private struct RecordingSidebar: View {
    @ObservedObject var model: Workbench
    @ObservedObject var media: MediaController
    let query: String
    let filter: LibraryContentFilter
    private var jobs: [MediaJob] {
        media.jobs.filter { filter.includes($0) && (query.isEmpty || ($0.sourceName + " " + $0.targetNote + " " + $0.subject).localizedCaseInsensitiveContains(query)) }
            .sorted { $0.classDate > $1.classDate }
    }
    var body: some View {
        Group {
            if jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: query.isEmpty ? filter.symbol : "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? (filter == .video ? "Sin vídeos" : "Sin audio") : "Sin resultados").font(.callout).foregroundStyle(.secondary)
                    if query.isEmpty {
                        Button(filter == .video ? "Importar vídeo…" : "Importar audio…") { model.importMedia() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(jobs) { job in
                            let status = RecordingPresentation(job: job)
                            Button {
                                model.openNote(job.targetNote)
                                media.select(job.id)
                                model.selectedTab = job.transcript.isEmpty ? "library" : "replay"
                                model.showInspector = true
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 7) {
                                        Image(systemName: status.symbol).foregroundStyle(status.color)
                                        Text(job.sourceName).font(.callout.weight(.medium)).lineLimit(1)
                                    }
                                    Text(URL(fileURLWithPath: job.targetNote).deletingPathExtension().lastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(job.classDate, format: .dateTime.day().month(.abbreviated))
                                        Text("·")
                                        Text(timestamp(job.duration)).monospacedDigit()
                                        Spacer(minLength: 0)
                                        Text(status.title).foregroundStyle(status.color).lineLimit(1)
                                    }.font(.system(size: 10))
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(media.selectedID == job.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(media.selectedID == job.id ? Color.accentColor.opacity(0.25) : .clear))
                            }.buttonStyle(.plain).help(status.detail)
                                .accessibilityLabel("\(job.sourceName), \(status.title), \(timestamp(job.duration))")
                        }
                    }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
                }
            }
        }
    }
}

struct NoteRecordingStatus: View {
    @ObservedObject var model: Workbench
    @ObservedObject var media: MediaController
    private var linked: [MediaJob] { media.jobs.filter { $0.targetNote == model.selectedNote }.sorted { $0.importedAt > $1.importedAt } }
    private var selected: MediaJob? { linked.first(where: { $0.id == media.selectedID }) ?? linked.first }
    var body: some View {
        if let job = selected {
            let status = RecordingPresentation(job: job)
            Button {
                media.select(job.id)
                model.selectedTab = job.transcript.isEmpty ? "library" : "replay"
                model.showInspector = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text(status.title).foregroundStyle(status.color)
                            Text("· \(timestamp(job.duration))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(status.title).foregroundStyle(status.color)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }.font(.caption).lineLimit(1)
            }.buttonStyle(.plain).help(status.detail)
                .accessibilityLabel("Abrir grabación de esta nota: \(status.title)")
        } else if model.isDirty {
            Label("Sin guardar", systemImage: "circle.fill").font(.caption2).foregroundStyle(.secondary)
        } else if model.selectedNote != nil {
            Label("Guardado", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RecordingMenuIcon: View {
    @ObservedObject var media: MediaController
    var body: some View {
        Image(systemName: "waveform").foregroundStyle(media.isRecording ? Color.red : Color.secondary).frame(width: 34, height: 32)
    }
}
