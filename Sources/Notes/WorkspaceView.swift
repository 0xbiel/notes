import SwiftUI
import LectureCore
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chrome = CompactChrome()
    @AppStorage("notes.language") private var language = "es"

    @State private var preferencesSection: NotebookPreferencesSection = .general

    private let sidebarWidth = CompactLayout.sidebarWidth
    /// The compact sidebar floats over the document, so the title bar starts past it.
    private var titleBarInset: CGFloat {
        chrome.compact && chrome.sidebarVisible ? sidebarWidth + CompactLayout.horizontalInset - 8 : 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: chrome.compact ? 0 : sidebarWidth)
                VStack(spacing: 0) {
                    if model.mapVisible {
                        // The atlas carries its own title bar.
                    } else if model.selectedNote == nil && model.selectedFile == nil, let assistant = model.assistant {
                        NotebookChatTitleBar(model: model, assistant: assistant, leadingInset: titleBarInset)
                    } else {
                        WorkspaceTitleBar(model: model, leadingInset: titleBarInset)
                    }
                    NoteWorkspace(model: model)
                    if model.assistant == nil {
                        HStack { Spacer(); ListeningDock(model: model) }.padding(12)
                    } else if model.selectedLibraryPath != nil && model.hideStudyComposer, let media = model.media {
                        RecordingOnlyDock(model: model, media: media)
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
                    if let media = model.media, let assistant = model.assistant, let ai = model.ai {
                        NotebookStatusIndicator(media: media, assistant: assistant, ai: ai).padding(.top, 2)
                    }
                }

            }
            library
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
            if model.showOnboarding {
                OnboardingView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
            }
            // The real window buttons sit where the sidebar header leaves room, above the introduction.
            let sidebarControls = chrome.compact && !model.showOnboarding
            NativeWindowControls(chrome: chrome).frame(width: 76, height: 34)
                .padding(.leading, 18 + (sidebarControls ? CompactLayout.horizontalInset : 0))
                .padding(.top, sidebarControls ? CompactLayout.verticalInset + 8 : 12)
                .opacity(chrome.sidebarVisible || model.showOnboarding ? 1 : 0)
                .offset(x: chrome.sidebarVisible || model.showOnboarding ? 0 : -sidebarWidth)
                .allowsHitTesting(chrome.sidebarVisible || model.showOnboarding)
        }
        .tint(.gray).accentColor(.gray)
        .background(NotebookAccentCaret())
        .background(AppScrollbarAppearance())
        .environment(\.locale, Locale(identifier: language))
        .background(NotebookThemeBackground(blendsBehindWindow: true))
        .background(CompactWindowBridge(chrome: chrome, modalPresented: model.showQuickOpen || model.creationKind != nil || model.renamingItem != nil || model.errorText != nil || model.showNotebookManagement))
        .focusedSceneObject(chrome)
        .onGeometryChange(for: Bool.self) { $0.size.width < 900 } action: { narrow in
            if narrow && !chrome.compact { chrome.toggleCompact() }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chrome.compact)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chrome.sidebarVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: model.showOnboarding)
        .onChange(of: model.showPreferences) { _, presented in
            if presented { preferencesSection = model.requestedPreferencesSection; model.requestedPreferencesSection = .general }
        }
        .sheet(isPresented: $model.showNotebookManagement) {
            if let assistant = model.assistant { NotebookManagement(model: model, assistant: assistant, notebook: model.currentNotebook) }
        }
        .sheet(isPresented: $model.showQuickOpen) { QuickOpenSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.creationKind != nil }, set: { if !$0 { model.creationKind = nil } })) {
            NotebookCreationSheet(model: model, kind: model.creationKind ?? "nota") { model.creationKind = nil }
        }
        .sheet(isPresented: Binding(get: { model.renamingItem != nil }, set: { if !$0 { model.renamingItem = nil } })) {
            if let item = model.renamingItem { LibraryRenameSheet(model: model, item: item) }
        }
        .alert("No se aplicó el cambio", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("Cerrar", role: .cancel) { model.errorText = nil }
        } message: { Text(NotebookAssistantText.display(model.errorText ?? "", language: language)) }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 76, height: 34)
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


}

/// Observe chat changes directly so the title bar appears when the first message is added.
struct NotebookChatTitleBar: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    var leadingInset: CGFloat = 0
    var body: some View {
        WorkspaceTitleBar(model: model, leadingInset: leadingInset)
    }
}

struct WorkspaceTitleBar: View {
    @ObservedObject var model: Workbench
    var leadingInset: CGFloat = 0
    private var notebookName: String { model.currentNotebook.name }
    @State private var actionsPresented = false
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                noteLocation
                Spacer(minLength: 8)
                if model.selectedLibraryPath != nil {
                    Button { model.hideStudyComposer.toggle() } label: {
                        Image(systemName: model.hideStudyComposer ? "bubble.left" : "bubble.left.fill")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .modifier(ControlHoverBackground(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language == "en" ? (model.hideStudyComposer ? "Show assistant" : "Hide assistant") : (model.hideStudyComposer ? "Mostrar asistente" : "Ocultar asistente"))
                    .accessibilityIdentifier("notebook.toggleAssistant")
                    .help(language == "en" ? (model.hideStudyComposer ? "Show assistant" : "Hide assistant") : (model.hideStudyComposer ? "Mostrar asistente" : "Ocultar asistente"))
                }
                Button { actionsPresented.toggle() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .modifier(ControlHoverBackground(cornerRadius: 8))
                        .background(actionsPresented ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language == "en" ? "Workspace actions" : "Acciones del espacio de trabajo")
                .accessibilityIdentifier("workspace.toggleActions")
                .accessibilityAddTraits(actionsPresented ? .isSelected : [])
                .help(language == "en" ? "Show workspace actions" : "Mostrar acciones del espacio de trabajo")
                .popover(isPresented: $actionsPresented, arrowEdge: .bottom) { actionsPanel }
                if model.selectedNote != nil { NoteModeSelector(model: model).padding(.leading, 4) }
            }
            .padding(.leading, 12 + leadingInset).padding(.trailing, 14).frame(height: 48)
            .modifier(WindowDragArea())
            Divider().opacity(0.4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("workspace.titleBar")
    }

    private var actionsPanel: some View {
        let en = language == "en"
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(notebookName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(documentBreadcrumb ?? (en ? "Notebook home" : "Inicio del cuaderno"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            if let path = model.selectedNote ?? model.selectedFile {
                panelSection(en ? "Document" : "Documento") {
                    DocumentFileActions(model: model, path: path, vertical: true)
                    if model.selectedNote != nil {
                        Menu { NoteOptionsMenuItems(model: model) } label: {
                            Label(en ? "Note options" : "Opciones de la nota", systemImage: "ellipsis.circle")
                        }.menuStyle(.button).menuIndicator(.hidden)
                            .accessibilityIdentifier("document.noteOptions")
                    }
                }
            }
            if let file = model.selectedFile, NotebookPracticeTest.isPracticeTest(file) {
                panelSection(en ? "View" : "Vista") {
                    NotebookPracticeLayoutSelector().padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
            panelSection(en ? "Notebook" : "Cuaderno") {
                Button { model.notebookCheckpointSelection = nil; model.showNotebookManagement = true; actionsPresented = false } label: {
                    Label(en ? "Manage notebook" : "Gestionar cuaderno", systemImage: "slider.horizontal.3")
                }
                NotebookColorMenu(model: model, notebook: model.currentNotebook).menuStyle(.button).menuIndicator(.hidden)
                if model.maps != nil {
                    Button { model.toggleMap(); actionsPresented = false } label: {
                        Label(en ? "Notebook map" : "Mapa del cuaderno", systemImage: "circle.hexagongrid")
                    }.accessibilityIdentifier("notebook.openMap")
                }
            }
        }
        .font(.system(size: 13))
        .labelStyle(WorkspacePanelLabelStyle())
        .buttonStyle(WorkspacePanelButtonStyle())
        .foregroundStyle(.primary)
        .padding(6).padding(.bottom, 2).frame(width: 280)
        .onExitCommand { actionsPresented = false }
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider().padding(.horizontal, 6).padding(.bottom, 6)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.bottom, 2)
            content()
        }.padding(.bottom, 6)
    }

    private var documentBreadcrumb: String? {
        guard let path = model.selectedLibraryPath else { return nil }
        let prefix = model.currentNotebook.rootPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = !prefix.isEmpty && path.hasPrefix(prefix + "/")
            ? String(path.dropFirst(prefix.count + 1)) : path
        var components = relative.components(separatedBy: "/").filter { !$0.isEmpty }
        if let filename = components.last {
            components[components.count - 1] = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        }
        return components.joined(separator: " / ")
    }

    private var breadcrumbComponents: [String] {
        documentBreadcrumb?.components(separatedBy: " / ") ?? []
    }

    private var noteLocation: some View {
        HStack(spacing: 4) {
            Button {
                model.expandNotebookChat()
                model.showMap = false
                actionsPresented = false
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(NotebookColor.color(for: model.currentNotebook) ?? Color.secondary.opacity(0.6))
                        .frame(width: 8, height: 8)
                    Text(notebookName)
                        .foregroundStyle(documentBreadcrumb == nil ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                    .fixedSize(horizontal: documentBreadcrumb != nil && notebookName.count <= 24, vertical: false)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .modifier(ControlHoverBackground(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.notebookHome")
            .help(language == "en" ? "Back to notebook home" : "Volver al inicio del cuaderno")
            let parts = breadcrumbComponents
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text("/").foregroundStyle(.tertiary)
                Text(part).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
                    .layoutPriority(index == parts.count - 1 ? 2 : 1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(minWidth: 100, alignment: .leading)
        .accessibilityElement(children: .contain)
        .help([notebookName, documentBreadcrumb].compactMap { $0 }.joined(separator: " / "))
    }

}

struct DocumentFileActions: View {
    @ObservedObject var model: Workbench
    let path: String
    var vertical = false
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Button { model.printSelectedDocument() } label: {
                Label(language == "en" ? "Print" : "Imprimir", systemImage: "printer")
            }.disabled(!model.canPrintDocument).accessibilityIdentifier("document.print")
            if ["md", "tex"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                Button { model.exportSelectedPDF() } label: {
                    Label(language == "en" ? "Export PDF" : "Exportar PDF", systemImage: "arrow.down.document")
                }.accessibilityIdentifier("document.exportPDF")
            }
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
        }.buttonStyle(WorkspacePanelButtonStyle()).font(.system(size: 13)).foregroundStyle(vertical ? .primary : .secondary)
            .fixedSize(horizontal: !vertical, vertical: true)
    }
}

/// Custom because AppKit segmented controls don't receive clicks inside the hidden title bar.
/// Tuned to the macOS 26 segmented control: the glass thumb lifts on press, tracks the pointer, then settles.
struct NoteModeSelector: View {
    @ObservedObject var model: Workbench
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat?
    @State private var pressed = false
    private let segment: CGFloat = 56
    private let modes = [("Editar", "edit"), ("Ver", "preview")]
    private var restingOffset: CGFloat { model.layout == "preview" ? segment : 0 }
    private var thumbOffset: CGFloat { dragOffset ?? restingOffset }
    private var hovered: String { thumbOffset < segment / 2 ? "edit" : "preview" }

    var body: some View {
        ZStack(alignment: .leading) {
            thumb
                .frame(width: segment, height: 26)
                .scaleEffect(pressed ? 1.08 : 1)
                .offset(x: thumbOffset)
            HStack(spacing: 0) {
                ForEach(modes, id: \.1) { title, value in
                    Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovered == value ? .primary : .secondary)
                        .frame(width: segment, height: 26)
                        .accessibilityAddTraits(model.layout == value ? .isSelected : [])
                }
            }.allowsHitTesting(false)
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            if !pressed { animate { pressed = true } }
            // Small moves are treated as a click; the thumb only tracks once the pointer travels.
            guard abs(drag.translation.width) > 3 else { return }
            dragOffset = min(max(drag.location.x - 2 - segment / 2, 0), segment)
        }.onEnded { drag in
            let target = abs(drag.translation.width) > 3 ? hovered : (drag.location.x < segment + 2 ? "edit" : "preview")
            animate { model.layout = target; dragOffset = nil; pressed = false }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Modo de la nota")
        .accessibilityValue(model.layout == "edit" ? "Editar" : "Ver")
        .accessibilityAdjustableAction { _ in animate { model.layout = model.layout == "edit" ? "preview" : "edit" } }
        .help("Editar o ver la nota · ⌘E")
    }

    @ViewBuilder private var thumb: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Capsule().fill(.clear).glassEffect(pressed ? .clear.interactive() : .regular.interactive(), in: .capsule)
                .shadow(color: .black.opacity(pressed ? 0.12 : 0.06), radius: pressed ? 6 : 2, y: 1)
        } else {
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
        }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), change)
    }
}

struct NoteOptionsMenuItems: View {
    @ObservedObject var model: Workbench
    var body: some View {
        Button("Marcar/desmarcar tarea") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownTask(_:)), to: nil, from: nil) }.keyboardShortcut("l", modifiers: [.command, .shift])
        Section("Formato") {
            Button("Negrita") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownBold(_:)), to: nil, from: nil) }.keyboardShortcut("b")
            Button("Cursiva") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownItalic(_:)), to: nil, from: nil) }.keyboardShortcut("i")
            Button("Código en línea") { NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownCode(_:)), to: nil, from: nil) }.keyboardShortcut("k", modifiers: [.command, .shift])
        }.disabled(model.layout != "edit" || model.selectedNote == nil)
        Button("Insertar tabla…") { NSApp.sendAction(#selector(MarkdownTextView.insertMarkdownTable(_:)), to: nil, from: nil) }.disabled(model.layout != "edit" || model.selectedNote == nil)
        Divider()
        Button("Deshacer edición guardada") { model.undoEditor() }
            .disabled(model.isDirty || model.editor?.history.contains(where: { !$0.undone && $0.superseded != true }) != true)
        Divider()
        Button("Nueva nota") { model.creationInitialName = ""; model.creationKind = "nota" }
        Button("Nuevo documento LaTeX") { model.creationInitialName = ""; model.creationKind = "latex" }
        Button("Nueva carpeta") { model.creationInitialName = ""; model.creationKind = "carpeta" }
        Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
    }
}

enum NotebookSidebarSelection: Hashable, Codable { case notebook(String), note(String), folder(String) }

struct CourseSidebar: View {
    @ObservedObject var model: Workbench
    @State private var query = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("notes.accent") private var accent = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar", text: $query).textFieldStyle(.plain).accessibilityLabel("Filtrar archivos")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).modifier(ControlHoverBackground()).help("Limpiar búsqueda")
                    }
                }.padding(.horizontal, 11).frame(height: 38)
                    .modifier(SidebarSearchGlass())
                Button { model.creationInitialName = ""; model.creationKind = "nota" } label: {
                    Image(systemName: "square.and.pencil").frame(width: 28, height: 38)
                }.buttonStyle(.plain).modifier(ControlHoverBackground()).help("Nueva nota · ⌘N").accessibilityLabel("Nueva nota")
            }.padding(.horizontal, 8)
            ScrollViewReader { proxy in
            List(selection: Binding<Set<NotebookSidebarSelection>>(get: {
                model.librarySelections
            }, set: { values in DispatchQueue.main.async { model.setLibrarySelections(values) } })) {
                ForEach(model.activeNotebooks) { notebook in
                    DisclosureGroup(isExpanded: Binding(get: { model.sidebarExpanded.contains(.notebook(notebook.id)) || !query.isEmpty }, set: { value in if value { model.sidebarExpanded.insert(.notebook(notebook.id)) } else { model.sidebarExpanded.remove(.notebook(notebook.id)) } })) {
                        let filenames = model.fileNames(in: notebook).filter { LibraryContentFilter.notes.includes(path: $0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
                        let relativeNames = filenames.map { notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)) }
                        let folders = query.isEmpty ? model.folderNames(in: notebook).map { notebook.rootPrefix.isEmpty ? $0 : String($0.dropFirst(notebook.rootPrefix.count + 1)) } : []
                        ForEach(NotebookNode.tree(notes: relativeNames, folderNames: folders, prefix: notebook.rootPrefix.isEmpty ? "" : notebook.rootPrefix + "/")) { node in
                            CourseTreeRow(model: model, node: node, expandAll: !query.isEmpty) { folder in prepareCreation("nota", folder: folder, notebook: notebook) }
                        }
                    } label: {
                        Button { model.openNotebook(notebook.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "book.closed.fill").foregroundStyle(NotebookColor.color(for: notebook).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary)).frame(width: 18, height: 20, alignment: .center)
                                Text(notebook.name).font(.callout.weight(.semibold))
                                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 2)
                                Text("\(model.fileNames(in: notebook).filter { LibraryContentFilter.notes.includes(path: $0) }.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).padding(.leading, 8).padding(.trailing, 2).contentShape(Rectangle())
                                // The native outline arrow follows the label baseline; anchor it to the row center.
                                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] + 2 }
                        }.buttonStyle(.plain)
                            .background(LibraryRowMarker(item: .notebook(notebook.id)))
                            .accessibilityIdentifier("notebook.open." + notebook.id)
                            .accessibilityAddTraits(model.selectedNotebookID == notebook.id && model.selectedLibraryPath == nil ? .isSelected : [])

                        .contextMenu {
                            Button("Nueva nota") { prepareCreation("nota", folder: notebook.rootPrefix, notebook: notebook) }
                            Button("Nueva carpeta") { prepareCreation("carpeta", folder: notebook.rootPrefix, notebook: notebook) }
                            Button("Importar archivos…") { model.chooseLibraryImport(into: notebook.rootPrefix, notebookID: notebook.id) }.disabled(!model.canManageFiles)
                            FolderImportOptions(model: model, notebookID: notebook.id)
                            Divider()
                            Button(UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Rename…" : "Renombrar…") { model.renamingItem = .notebook(notebook.id) }.disabled(!model.canManageFiles)
                            NotebookColorMenu(model: model, notebook: notebook)
                            Button("Copiar cuaderno") { model.copyLibraryItem(.notebook(notebook.id)) }.disabled(!model.canManageFiles)
                            Button("Pegar") { model.pasteLibraryItems(into: notebook.rootPrefix, notebookID: notebook.id) }.disabled(!model.canManageFiles)
                            Divider()
                            Button("Mover cuaderno arriba") {
                                let ids = model.activeNotebooks.map(\.id)
                                if let index = ids.firstIndex(of: notebook.id), index > 0 { model.reorderNotebook(notebook.id, relativeTo: ids[index - 1]) }
                            }.disabled(model.activeNotebooks.first?.id == notebook.id)
                            Button("Mover cuaderno abajo") {
                                let ids = model.activeNotebooks.map(\.id)
                                if let index = ids.firstIndex(of: notebook.id), index + 1 < ids.count { model.reorderNotebook(notebook.id, relativeTo: ids[index + 1], after: true) }
                            }.disabled(model.activeNotebooks.last?.id == notebook.id)
                            Divider()
                            Button("Eliminar cuaderno", role: .destructive) { model.deleteNotebook(notebook) }.disabled(!model.canManageFiles)
                        }
                    }
                    .modifier(LibraryDropTarget(model: model, directory: notebook.rootPrefix, notebookID: notebook.id))
                    .tag(NotebookSidebarSelection.notebook(notebook.id))
                    .id(notebook.id)

                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).background(NeutralSidebarSelection(model: model))
                .onChange(of: model.notebookRevealRequest) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo(model.selectedNotebookID, anchor: .center) }
                }
                .onAppear {
                    if model.notebookRevealRequest > 0 {
                        DispatchQueue.main.async { proxy.scrollTo(model.selectedNotebookID, anchor: .center) }
                    }
                }
                .contextMenu {
                    Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                    ImportFolderAsNotebookButton(model: model)
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
                    FolderImportOptions(model: model, notebookID: model.currentNotebook.id)
                } label: { Image(systemName: "plus").frame(width: 28, height: 34).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Añadir nota, carpeta o cuaderno").accessibilityLabel("Añadir")
                Button { model.showPreferences = true } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }.buttonStyle(.plain).modifier(ControlHoverBackground()).help("Preferencias · ⌘,").accessibilityLabel("Preferencias")
                NotebookSortSelector(model: model)
                Spacer()
                NotebookTrashMenu(model: model)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(NotebookLibraryClipboard(model: model))
            .contextMenu {
                Button("Nuevo cuaderno") { model.creationInitialName = ""; model.creationKind = "cuaderno" }
                ImportFolderAsNotebookButton(model: model)
            }
            .onChange(of: model.selectedNotebookID) { _, id in model.sidebarExpanded.insert(.notebook(id)) }
            .onChange(of: model.libraryExpandRequest) { _, item in if case .notebook = item, let item { model.sidebarExpanded.insert(item) } }
            .onChange(of: model.notebookRevealRequest) { _, _ in
                query = ""; model.sidebarExpanded.insert(.notebook(model.selectedNotebookID))
            }

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
    private var expanded: Bool {
        get { model.sidebarExpanded.contains(.folder(node.path)) }
        nonmutating set { if newValue { model.sidebarExpanded.insert(.folder(node.path)) } else { model.sidebarExpanded.remove(.folder(node.path)) } }
    }
    var body: some View {
        Group {
            if let children = node.children {
                // A search opens every folder for its duration without changing what is remembered.
                DisclosureGroup(isExpanded: Binding(get: { expanded || expandAll }, set: { expanded = $0 })) {
                    ForEach(children) { child in CourseTreeRow(model: model, node: child, expandAll: expandAll, createInFolder: createInFolder) }
                } label: {
                    HStack(spacing: 9) {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").frame(width: 18, height: 20, alignment: .center)
                            Text(node.name).lineLimit(2).truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }.background(LibraryRowMarker(item: .folder(node.path)))
                        Spacer(minLength: 2)
                    }.foregroundStyle(.secondary).font(.callout)
                        .padding(.vertical, 6).padding(.leading, 8).padding(.trailing, 2)
                        .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] + 2 }
                        .contextMenu {
                            Button("Nueva nota aquí") { createInFolder(node.path) }
                            Button("Nueva carpeta aquí") { model.createFolderInside(node.path) }
                            Button("Importar archivos…") { if let owner = model.projects?.owner(of: node.path + "/placeholder") { model.chooseLibraryImport(into: node.path, notebookID: owner.id) } }.disabled(!model.canManageFiles)
                            Divider()
                            Button(UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Rename…" : "Renombrar…") { model.renamingItem = .folder(node.path) }.disabled(!model.canManageFiles)
                            Button("Copiar carpeta") { model.copyLibraryItem(.folder(node.path)) }.disabled(!model.canManageFiles)
                            Button("Pegar") { if let owner = model.projects?.owner(of: node.path + "/placeholder") { model.pasteLibraryItems(into: node.path, notebookID: owner.id) } }.disabled(!model.canManageFiles)
                            LibraryMoveMenu(model: model, path: node.path, folder: true)
                            Divider()
                            Button("Eliminar carpeta", role: .destructive) { model.deleteItem(node.path, folder: true) }.disabled(!model.canManageFiles)
                        }
                }
                .tag(NotebookSidebarSelection.folder(node.path))
                .modifier(LibraryDropTarget(model: model, directory: node.path, notebookID: model.projects?.owner(of: node.path + "/placeholder")?.id ?? ""))
                .onAppear { revealSelection() }
                .onChange(of: model.selectedLibraryPath) { _, _ in revealSelection() }
                .onChange(of: model.selectedFolder) { _, _ in revealSelection() }
                .onChange(of: model.libraryExpandRequest) { _, item in if item == .folder(node.path) { expanded = true } }
            } else {
                HStack(spacing: 9) {
                    HStack(spacing: 9) {
                        // One width for every symbol, so titles line up whatever the file type.
                        Image(systemName: LibraryFileIcon.symbol(node.path)).frame(width: 18)
                            .foregroundStyle(model.selectedLibraryPath == node.path ? .primary : .secondary)
                        Text(node.name).font(.callout).lineLimit(2)
                    }.background(LibraryRowMarker(item: .note(node.path)))
                    Spacer(minLength: 2)
                    if model.hasDraft(for: node.path) { Circle().fill(Color.orange).frame(width: 5, height: 5).accessibilityLabel("Sin guardar") }
                }.padding(.vertical, 6).padding(.horizontal, 2)
                    .help(node.name).tag(NotebookSidebarSelection.note(node.path))
                    .contextMenu {
                        Button("Abrir") { model.openLibraryFile(node.path) }
                        if node.path.hasSuffix(".md") {
                            Button("Editar") { model.openNote(node.path); model.layout = "edit" }
                            Button("Ver") { model.openNote(node.path); model.layout = "preview" }
                        }
                        Divider()
                        Button(UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Rename…" : "Renombrar…") { model.renamingItem = .note(node.path) }.disabled(!model.canManageFiles)
                        Button("Copiar archivo") { model.copyLibraryItem(.note(node.path)) }.disabled(!model.canManageFiles)
                        LibraryMoveMenu(model: model, path: node.path, folder: false)
                        Divider()
                        Button("Eliminar documento", role: .destructive) { model.deleteItem(node.path, folder: false) }.disabled(!model.canManageFiles)
                    }
            }
        }
    }
    private func revealSelection() {
        if model.selectedLibraryPath?.hasPrefix(node.path + "/") == true || model.selectedFolder == node.path || model.selectedFolder?.hasPrefix(node.path + "/") == true { expanded = true }
    }
}

struct NoteWorkspace: View {
    @ObservedObject var model: Workbench
    @State private var composerHeight: CGFloat = 130
    @State private var quizFooterHeight: CGFloat = 64
    private var showsComposer: Bool { model.showsDocumentComposer }
    private var isPracticeTest: Bool { model.selectedFile.map(NotebookPracticeTest.isPracticeTest) == true }
    var body: some View {
        Group {
            if model.activeNotebooks.isEmpty {
                NotebookEmptyLibrary(model: model)
            } else if let file = model.selectedFile, let workspace = model.workspace {
                if LaTeXDocument.isSource(file), let controller = try? model.latexController(file) {
                    LaTeXEditor(controller: controller, bottomInset: showsComposer ? composerHeight : 0).id(file)
                } else {
                    NotebookFilePreview(workspace: workspace, path: file, bottomInset: showsComposer ? composerHeight : 0,
                        imageRoot: workspace.courseRoot.appendingPathComponent(model.currentNotebook.rootPrefix), onFooterHeight: { quizFooterHeight = $0 })
                }
            } else if let note = model.selectedNote {
                LiveMarkdownEditor(documentID: note, text: model.draftText, editing: model.layout == "edit", heading: model.previewHeading,
                    bottomInset: showsComposer ? composerHeight : 0,
                    imageDirectory: model.workspace?.courseRoot.appendingPathComponent(note).deletingLastPathComponent(),
                    imageRoot: model.workspace?.courseRoot.appendingPathComponent(model.currentNotebook.rootPrefix),
                    importImage: { data, ext in try model.importDocumentImage(data, fileExtension: ext, note: note) },
                    onChange: { model.changeDraft($0) }, onLink: { _ = model.openWikilink($0) }, onTaskToggle: { _ in if model.layout == "preview" { model.saveDraft() } })
            } else if model.mapVisible, let maps = model.maps {
                NotebookAtlasView(model: model, maps: maps)
            } else {
                if let assistant = model.assistant { NotebookHome(model: model, assistant: assistant) }
                else { ContentUnavailableView("Abre una nota", systemImage: "doc.text", description: Text("⇧⌘P para buscar")) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if showsComposer, let assistant = model.assistant {
                NotebookComposer(model: model, assistant: assistant).frame(maxWidth: 740)
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                    .padding(.bottom, isPracticeTest ? quizFooterHeight : 0)
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
            Button { model.notebookCheckpointSelection = nil; model.showNotebookManagement = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34) }
                .buttonStyle(NotebookSolidButtonStyle()).help("Gestionar cuaderno").accessibilityLabel("Gestionar cuaderno").accessibilityIdentifier("notebook.manage")
            if let media = model.media { MicrophoneButton(model: model, media: media, compact: embedded) }

        }.padding(embedded ? 0 : 6)
    }
}

struct QuickOpenSheet: View {
    @ObservedObject var model: Workbench
    @State private var query = ""
    @State private var selection: QuickOpenResult?
    @AppStorage("notes.language") private var language = "es"
    @FocusState private var focused: Bool
    private var matches: [QuickOpenResult] { model.quickOpenMatches(query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(language == "en" ? "Search notebooks, files or preferences…" : "Buscar cuadernos, archivos o preferencias…", text: $query).textFieldStyle(.plain).font(.title3).focused($focused)
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
                    ForEach(matches) { result in
                        Button { open(result) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol(result)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(result)).lineLimit(1)
                                    Text(subtitle(result)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if selected(result) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).tag(result)
                            .accessibilityIdentifier(identifier(result))
                    }
                }.listStyle(.plain).frame(height: 280)
                    .onKeyPress(.return) { open(selection ?? matches.first); return .handled }
            }
            HStack { Text("↵ abrir"); Spacer(); Text("esc cerrar") }.font(.caption).foregroundStyle(.secondary).padding(14)
        }.frame(width: 580)
            .onAppear { focused = true; selection = matches.first }
            .onChange(of: query) { _, _ in selection = matches.first }
            .onExitCommand { model.showQuickOpen = false }
    }
    private func open(_ result: QuickOpenResult?) {
        guard let result else { return }
        model.openQuickOpenResult(result)
    }
    private func symbol(_ result: QuickOpenResult) -> String {
        switch result {
        case .notebook: "book.closed"
        case .file: "doc.text"
        case .preferences: "gearshape"
        }
    }
    private func title(_ result: QuickOpenResult) -> String {
        switch result {
        case .notebook(let id): model.activeNotebooks.first { $0.id == id }?.name ?? ""
        case .file(let path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .preferences: language == "en" ? "Preferences" : "Preferencias"
        }
    }
    private func subtitle(_ result: QuickOpenResult) -> String {
        switch result {
        case .notebook(let id):
            let count = model.activeNotebooks.first { $0.id == id }.map { model.fileNames(in: $0).count } ?? 0
            return language == "en" ? "Notebook · \(count) \(count == 1 ? "file" : "files")" : "Cuaderno · \(count) \(count == 1 ? "archivo" : "archivos")"
        case .file(let path): return path
        case .preferences: return language == "en" ? "General and theme" : "General y tema"
        }
    }
    private func selected(_ result: QuickOpenResult) -> Bool {
        switch result {
        case .notebook(let id): model.librarySelection == .notebook(id)
        case .file(let path): model.selectedLibraryPath == path
        case .preferences: model.showPreferences
        }
    }
    private func identifier(_ result: QuickOpenResult) -> String {
        switch result {
        case .notebook(let id): "search.notebook." + id
        case .file(let path): "search.file." + path
        case .preferences: "search.preferences"
        }
    }
    private func moveSelection(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let index = selection.flatMap { matches.firstIndex(of: $0) } ?? 0
        selection = matches[max(0, min(matches.count - 1, index + offset))]
    }
}

struct MicrophoneButton: View {
    @ObservedObject var model: Workbench
    @ObservedObject var media: MediaController
    var compact = false
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        Button { model.toggleMicrophone() } label: {
            HStack(spacing: 8) {
                if media.busy && !media.isRecording { ProgressView().controlSize(.small) }
                else { Image(systemName: media.isRecording ? "stop.fill" : "mic.fill") }
                if !compact { Text(media.isRecording ? (language == "en" ? "Stop dictation" : "Detener dictado") : (language == "en" ? "Dictate" : "Dictar")) }
            }.padding(.horizontal, compact ? 0 : 12).padding(.vertical, compact ? 0 : 8)
                .frame(minWidth: 34, minHeight: 34)
        }.accessibilityLabel(media.isRecording ? (language == "en" ? "Stop dictation" : "Detener dictado") : (language == "en" ? "Dictate into chat" : "Dictar en el chat"))
            .accessibilityIdentifier("notebook.dictation")
            .buttonStyle(NotebookSolidButtonStyle()).foregroundStyle(media.isRecording ? Color.red : Color.primary)
            .disabled(!media.isRecording && (media.busy || model.busy || media.modelOperation != nil))
            .help(language == "en" ? "Dictate into the message box. Review before sending." : "Dicta en el cuadro de mensaje. Revísalo antes de enviar.")
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
        guard !job.syntheticFixture else { return false }
        if job.isMicrophone { return self == .audio }
        return self != .notes && includes(path: job.sourceName)
    }
    func includes(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let video = type?.conforms(to: .movie) == true || ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(ext)
        let audio = !video && (type?.conforms(to: .audio) == true || ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff", "caf"].contains(ext))
        switch self {
        case .notes: return !video && !audio
        case .audio: return audio
        case .video: return video
        }
    }
    func recordings(_ jobs: [MediaJob], notebookID: String, query: String) -> [MediaJob] {
        jobs.filter {
            $0.notebookID == notebookID && includes($0) &&
            (query.isEmpty || ([$0.sourceName, $0.targetNote, $0.subject] + $0.unitTags + $0.examTags).joined(separator: " ").localizedCaseInsensitiveContains(query))
        }.sorted { $0.classDate == $1.classDate ? $0.id < $1.id : $0.classDate > $1.classDate }
    }
}

struct FolderImportOptions: View {
    @ObservedObject var model: Workbench
    let notebookID: String
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        Button(language == "en" ? "Import folder contents into notebook…" : "Importar contenido de carpeta al cuaderno…") {
            model.chooseFolderImport(notebookID: notebookID, asNotebook: false)
        }.disabled(!model.canManageFiles || model.activeNotebooks.isEmpty)
        ImportFolderAsNotebookButton(model: model)
    }
}

private struct ImportFolderAsNotebookButton: View {
    @ObservedObject var model: Workbench
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        Button(language == "en" ? "Import folder as new notebook…" : "Importar carpeta como nuevo cuaderno…") {
            model.chooseFolderImport(notebookID: model.currentNotebook.id, asNotebook: true)
        }.disabled(!model.canManageFiles)
    }
}

private struct RecordingOnlyDock: View {
    @ObservedObject var model: Workbench
    @ObservedObject var media: MediaController
    var body: some View {
        if media.isRecording { HStack { Spacer(); ListeningDock(model: model) }.padding(12) }
    }
}

/// Full-width rows mirror the compact utility panel in T3 Code.
struct WorkspacePanelLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(.secondary).frame(width: 20)
            configuration.title.lineLimit(1)
            Spacer(minLength: 10)
        }
    }
}

struct WorkspacePanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 8)
            .background(configuration.isPressed ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .modifier(ControlHoverBackground())
    }
}
