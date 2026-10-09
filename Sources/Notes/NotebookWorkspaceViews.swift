import SwiftUI
import LectureCore
import UniformTypeIdentifiers

struct NotebookHome: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    @AppStorage("notes.language") private var language = "es"
    private var notebook: Notebook { model.currentNotebook }
    private var empty: Bool { assistant.chat(notebook)?.messages.isEmpty != false && assistant.unrepresentedError(notebook) == nil }
    var body: some View {
        VStack(spacing: 18) {
            NotebookChatPicker(notebook: notebook, assistant: assistant).padding(.top, 20)
            if empty {
                Spacer(minLength: 20)
                VStack(spacing: 10) {
                    NotebookHomePicker(model: model)
                    Text(language == "en" ? "What would you like to work on?" : "¿En qué quieres trabajar?").foregroundStyle(.secondary)
                }
            } else {
                NotebookConversation(model: model, assistant: assistant).padding(16).frame(maxHeight: .infinity)
            }
            NotebookComposer(model: model, assistant: assistant, large: true).frame(maxWidth: 740)
            if empty { Spacer(minLength: 35) }
        }.padding(.horizontal, 30).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

    }
}

struct NotebookHomePicker: View {
    @ObservedObject var model: Workbench
    @AppStorage("notes.accent") private var accent = ""
    @State private var titleHovered = false
    @AppStorage("notes.language") private var language = "es"
    @State private var presented = false
    @State private var search = ""
    @State private var hovered: String?
    private var notebooks: [Notebook] {
        model.activeNotebooks.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        Button { search = ""; presented = true } label: {
            Text(model.currentNotebook.name)
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.bottom, 9)
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: CGPoint(x: 1.5, y: 1.5))
                            path.addLine(to: CGPoint(x: max(1.5, geometry.size.width - 1.5), y: 1.5))
                        }.stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 9]))
                            .foregroundStyle(titleHovered ? NotebookAccent.color(accent) : Color.secondary.opacity(0.75))
                    }.frame(height: 3)
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .onHover { titleHovered = $0 }
            .accessibilityIdentifier("notebook.homePicker")
            .accessibilityLabel(language == "en" ? "Choose notebook" : "Elegir cuaderno")
            .accessibilityValue(model.currentNotebook.name)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(language == "en" ? "Search notebooks…" : "Buscar cuadernos…", text: $search)
                            .textFieldStyle(.plain).accessibilityIdentifier("notebook.searchNotebooks")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel(language == "en" ? "Clear search" : "Borrar búsqueda")
                        }
                    }.padding(9)
                    Divider()
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(notebooks) { notebook in
                                Button {
                                    model.openNotebook(notebook.id)
                                    model.notebookRevealRequest += 1
                                    presented = false
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                                        Text(notebook.name).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        if model.selectedNotebookID == notebook.id {
                                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                        }
                                    }.padding(.horizontal, 8).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .background(model.selectedNotebookID == notebook.id || hovered == notebook.id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).onHover { hovered = $0 ? notebook.id : nil }
                                    .accessibilityIdentifier("notebook.choose." + notebook.id)
                                    .accessibilityAddTraits(model.selectedNotebookID == notebook.id ? .isSelected : [])
                            }
                            if notebooks.isEmpty {
                                Text(language == "en" ? "No notebooks found" : "No se encontraron cuadernos")
                                    .font(.callout).foregroundStyle(.secondary).padding(8)
                            }
                        }
                    }.frame(height: min(280, CGFloat(max(1, notebooks.count)) * 38))
                }.padding(5).frame(width: 290).background(Color(nsColor: .windowBackgroundColor))
                    .onExitCommand { presented = false }
            }
    }
}

struct NotebookChatPicker: View {
    let notebook: Notebook
    @ObservedObject var assistant: NotebookAssistantController
    @AppStorage("notes.language") private var language = "es"
    @State private var presented = false
    @State private var hovered: String?
    @State private var search = ""
    @State private var pendingDeletion: NotebookChat?
    @AppStorage("notes.confirmChatDeletion") private var confirmChatDeletion = true
    private var chats: [NotebookChat] { assistant.matchingChats(notebook, query: search) }
    private var title: String { assistant.chat(notebook)?.title ?? "Chats" }
    private var titleWidth: CGFloat { min(240, max(28, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up))) }
    var body: some View {
        HStack(spacing: 12) {
            Button { presented.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                    Text(title).lineLimit(1).truncationMode(.tail).frame(width: titleWidth, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.vertical, 8)
                    .modifier(NotebookInputSurface(radius: 7))
            }.buttonStyle(.plain)
                .accessibilityIdentifier("notebook.chatPicker")
                .accessibilityLabel(language == "en" ? "Choose chat" : "Elegir chat")
                .accessibilityValue(assistant.chat(notebook)?.title ?? "Chats")
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(language == "en" ? "Search chats…" : "Buscar chats…", text: $search)
                                .textFieldStyle(.plain).accessibilityIdentifier("notebook.searchChats")
                            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel(language == "en" ? "Clear search" : "Borrar búsqueda") }
                        }.padding(9)
                        Divider()
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(chats) { chat in
                                    HStack(spacing: 2) {
                                    Button { assistant.selectChat(chat.id, notebook: notebook); presented = false } label: {
                                        HStack(spacing: 7) {
                                            Text(chat.title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            if assistant.chat(notebook)?.id == chat.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                                        }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            .background(assistant.chat(notebook)?.id == chat.id || hovered == chat.id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain).onHover { hovered = $0 ? chat.id : nil }
                                        .accessibilityAddTraits(assistant.chat(notebook)?.id == chat.id ? .isSelected : [])
                                    Button {
                                        if confirmChatDeletion { pendingDeletion = chat }
                                        else {
                                            do { try assistant.deleteChat(chat.id, notebook: notebook) } catch { assistant.error = error.localizedDescription }
                                        }
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 26, height: 30)
                                    }.buttonStyle(.plain)
                                        .disabled(assistant.runningNotebookID == notebook.id && assistant.runningChatID == chat.id)
                                        .accessibilityLabel((language == "en" ? "Delete chat: " : "Eliminar chat: ") + chat.title)
                                    }
                                }
                                if chats.isEmpty { Text(language == "en" ? "No chats found" : "No se encontraron chats").font(.callout).foregroundStyle(.secondary).padding(8) }
                            }
                        }.frame(height: min(280, CGFloat(max(1, chats.count)) * 46))
                    }.padding(5).frame(width: 290).background(Color(nsColor: .windowBackgroundColor))
                        .onExitCommand { presented = false }
                        .alert(language == "en" ? "Delete chat?" : "¿Eliminar chat?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                            Button(language == "en" ? "Cancel" : "Cancelar", role: .cancel) { pendingDeletion = nil }
                            Button(language == "en" ? "Delete" : "Eliminar", role: .destructive) {
                                if let chat = pendingDeletion {
                                    do { try assistant.deleteChat(chat.id, notebook: notebook) } catch { assistant.error = error.localizedDescription }
                                }
                                pendingDeletion = nil
                            }
                        } message: { Text(language == "en" ? "This removes the conversation and its draft. Your documents and checkpoints are kept." : "Se eliminarán la conversación y su borrador. Se conservan los documentos y el historial.") }
                }
            Button {
                do { try assistant.newChat(notebook) } catch { assistant.error = error.localizedDescription }
            } label: { Label(language == "en" ? "New chat" : "Nuevo chat", systemImage: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("notebook.newChat")
        }.font(.callout)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain).accessibilityIdentifier("notebook.chatHeader")
    }
}

struct NotebookConversation: View {
    @State private var followsLatest = true
    @AppStorage("notes.language") private var language = "es"
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(assistant.chat(model.currentNotebook)?.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 9) {
                            if let activities = message.activities, !activities.isEmpty { NotebookWorkLog(activities: activities, failed: message.role == "error") }
                            if let attachments = message.attachments, !attachments.isEmpty {
                                NotebookAttachmentStrip(attachments: attachments, workspace: assistant.store.workspace)
                            }
                            NotebookChatMarkdown(text: NotebookAssistantText.message(message, language: language))
                                .foregroundStyle(message.role == "error" ? Color.orange : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !message.files.isEmpty { NotebookChangedFiles(model: model, assistant: assistant, message: message) }
                            if message.checkpointID != nil {
                                Button { model.notebookCheckpointSelection = message.checkpointID; model.showNotebookManagement = true } label: { Label("Ver cambios", systemImage: "clock.arrow.circlepath") }
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(message.role == "user" ? 14 : 4)
                            .background(.primary.opacity(message.role == "user" ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 14))
                            .padding(.leading, message.role == "user" ? 50 : 0)
                            .id(message.id)
                    }
                    if assistant.runningNotebookID == model.currentNotebook.id, assistant.runningChatID == assistant.chat(model.currentNotebook)?.id {
                        NotebookWorkLog(activities: assistant.activities, running: true).padding(.vertical, 8)
                    }
                    if let error = assistant.unrepresentedError(model.currentNotebook) {
                        HStack(alignment: .top, spacing: 8) {
                            NotebookChatMarkdown(text: NotebookAssistantText.display(error, language: language)).foregroundStyle(.orange)
                            Button { assistant.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                .accessibilityLabel(language == "en" ? "Dismiss error" : "Cerrar error")
                        }.padding(4).accessibilityIdentifier("notebook.chatError")
                    }
                    Color.clear.frame(height: 1).id("end").onAppear { followsLatest = true }.onDisappear { followsLatest = false }
                }.frame(maxWidth: 740).frame(maxWidth: .infinity).padding(.horizontal, 8)
            }
            .onChange(of: assistant.chat(model.currentNotebook)?.messages.count) { _, _ in if followsLatest { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: assistant.activities.count) { _, _ in if followsLatest { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct NotebookComposer: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    var large = false
    @State private var showConversation = false
    @State private var choosingAttachments = false
    @State private var dropTargeted = false
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.language") private var language = "es"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var notebook: Notebook { model.currentNotebook }
    private var draft: Binding<String> { Binding(get: { assistant.chat(notebook)?.draft ?? "" }, set: { assistant.setDraft($0, notebook: notebook) }) }
    private var running: Bool { assistant.runningNotebookID == notebook.id }
    var body: some View {
        VStack(spacing: 8) {
            if !large && showConversation {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        NotebookChatPicker(notebook: notebook, assistant: assistant).labelStyle(.iconOnly)
                        Button { showConversation = false } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                            .buttonStyle(.plain).accessibilityLabel(language == "en" ? "Close chat" : "Cerrar chat")
                            .accessibilityIdentifier("notebook.closeChat")
                    }
                    NotebookConversation(model: model, assistant: assistant)
                }.padding(14).frame(height: 280)
                    .modifier(NotebookInputSurface(radius: 18, floating: true, borderOpacity: 0.6))
                    .accessibilityIdentifier("notebook.floatingChat")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !running, !model.chatHistoryVisible, let error = assistant.composerError(notebook) {
                HStack(spacing: 8) {
                    Text(NotebookAssistantText.display(error, language: language)).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { assistant.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(language == "en" ? "Dismiss error" : "Cerrar error")
                }.padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .modifier(NotebookInputSurface(radius: 10))
                    .accessibilityIdentifier("notebook.composerError")
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: large ? 16 : 8) {
                if let attachments = assistant.chat(notebook)?.attachments, !attachments.isEmpty {
                    NotebookAttachmentStrip(attachments: attachments, workspace: assistant.store.workspace) { assistant.removeAttachment($0, notebook: notebook) }
                }
                if assistant.importingAttachments { HStack { ProgressView().controlSize(.small); Text(language == "en" ? "Preparing attachments…" : "Preparando archivos…").font(.caption).foregroundStyle(.secondary) } }
                TextField(language == "en" ? "Ask for changes or start a document…" : "Pide cambios o empieza un documento…", text: draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(large ? 3...8 : 1...6)
                    .onSubmit { model.submitNotebookPrompt() }
                    .background(NotebookAttachmentPasteTarget { assistant.pasteAttachments($0, notebook: notebook) })
                    .accessibilityLabel(language == "en" ? "Notebook assistant prompt" : "Mensaje al asistente del cuaderno")
                    .accessibilityIdentifier("notebook.composer")
                HStack(spacing: 8) {
                    if let ai = model.ai { NotebookModelControls(ai: ai, disabled: assistant.runningNotebookID != nil) { model.showPreferences = true } }
                    Spacer(minLength: 4)
                    Button { choosingAttachments = true } label: { Image(systemName: "paperclip").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(assistant.importingAttachments)
                        .accessibilityLabel(language == "en" ? "Attach files" : "Adjuntar archivos")
                        .accessibilityIdentifier("notebook.attachFiles")
                    ListeningDock(model: model, embedded: true)
                    if !large {
                        Button { showConversation.toggle() } label: { Image(systemName: showConversation ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).help(language == "en" ? "Toggle chat" : "Mostrar u ocultar chat").accessibilityLabel(language == "en" ? "Toggle chat" : "Mostrar u ocultar chat")
                            .modifier(NotebookInputSurface(radius: 7))
                            .accessibilityAddTraits(showConversation ? .isSelected : [])
                            .accessibilityIdentifier("notebook.showChat")
                    }
                    Button {
                        if running { assistant.stop() } else { model.submitNotebookPrompt() }
                    } label: {
                        Image(systemName: running ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(NotebookAccent.color(accent), in: Circle())
                    }.buttonStyle(.plain)
                        .disabled(!running && ((draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (assistant.chat(notebook)?.attachments ?? []).isEmpty) || assistant.runningNotebookID != nil || assistant.importingAttachments))
                        .accessibilityLabel(running ? (language == "en" ? "Stop" : "Detener") : (language == "en" ? "Send" : "Enviar"))
                        .accessibilityIdentifier("notebook.send")
                }
            }.padding(large ? 18 : 12)
                .modifier(NotebookInputSurface(radius: large ? 22 : 18, floating: !large, borderOpacity: 0.6))
                .overlay(RoundedRectangle(cornerRadius: large ? 22 : 18).stroke(dropTargeted ? NotebookAccent.color(accent) : .clear, lineWidth: 2))
                .dropDestination(for: URL.self) { urls, _ in
                    guard !assistant.importingAttachments, !urls.isEmpty else { return false }
                    assistant.importAttachments(urls, notebook: notebook); return true
                } isTargeted: { dropTargeted = $0 }
                .fileImporter(isPresented: $choosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): assistant.importAttachments(urls, notebook: notebook)
                    case .failure(let error): assistant.error = error.localizedDescription
                    }
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showConversation)
        .onExitCommand { showConversation = false }
        .onChange(of: notebook.id) { _, _ in showConversation = false }
        .onChange(of: showConversation) { _, value in if !large { model.documentChatVisible = value } }
        .onAppear { if !large { model.documentChatVisible = showConversation } }
        .onDisappear { if !large { model.documentChatVisible = false } }
    }
}

private struct NotebookModelControls: View {
    @ObservedObject var ai: AIController
    @StateObject private var preferences: ProviderPreferencesModel
    let disabled: Bool
    let manage: () -> Void
    init(ai: AIController, disabled: Bool, manage: @escaping () -> Void) {
        self.ai = ai; self.disabled = disabled; self.manage = manage
        _preferences = StateObject(wrappedValue: ProviderPreferencesModel(ai: ai))
    }
    var body: some View {
        ViewThatFits {
            HStack(spacing: 4) { selector; reasoning }
            selector
        }.controlSize(.small).disabled(disabled || ai.running)
            .onChange(of: preferences.draft) { _, _ in if preferences.hasChanges { preferences.save() } }
            .onChange(of: ai.providerSettings) { old, new in if preferences.draft == old { preferences.draft = new } }
            .task(id: preferences.catalogIdentity) { await preferences.refreshCatalogPeriodically() }
    }
    private var selector: some View { AIModelSelector(preferences: preferences, manageProviders: manage) }
    @ViewBuilder private var reasoning: some View {
        if preferences.draft.selectedProvider == .codexCLI, let selected = preferences.selectedModel, !selected.reasoning.isEmpty {
            AIOptionSelector(title: "Razonamiento", symbol: "brain", options: [.init(id: "auto", title: "Auto")] + selected.reasoning.map { .init(id: $0, title: $0.capitalized) }, selection: Binding(get: { preferences.draft.selected.reasoningEffort ?? "auto" }, set: { preferences.draft.selected.reasoningEffort = $0 == "auto" ? nil : $0 }))
        }
    }
}

struct NotebookManagement: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    let notebook: Notebook
    @State private var profile: NotebookProfile
    @State private var selection: String?
    @State private var tab = "profile"
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notes.language") private var language = "es"
    init(model: Workbench, assistant: NotebookAssistantController, notebook: Notebook) {
        self.model = model; self.assistant = assistant; self.notebook = notebook
        _profile = State(initialValue: assistant.state(notebook).profile)
        _selection = State(initialValue: model.notebookCheckpointSelection)
        _tab = State(initialValue: model.notebookCheckpointSelection == nil ? "profile" : "history")
    }
    private func t(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(notebook.name).font(.title2.weight(.semibold)); Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32)
                        .modifier(NotebookGlassCloseSurface())
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(t("Cerrar", "Close")).accessibilityIdentifier("notebook.management.close")
            }
            NotebookGlassSelector(selection: $tab, options: [
                .init(id: "profile", title: t("Perfil", "Profile")),
                .init(id: "history", title: t("Historial", "History"))
            ]).accessibilityIdentifier("notebook.management.tabs")
            if tab == "profile" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        field(t("Propósito", "Purpose"), text: $profile.purpose)
                        field(t("Instrucciones del asistente", "Assistant instructions"), text: $profile.instructions, lines: 4)
                        field(t("Estilo y formato", "Style and formatting"), text: $profile.formatting)
                        field(t("Reglas de fuentes", "Source rules"), text: $profile.sourceRules)
                    }.padding(2)
                }
                HStack { Spacer(); Button { assistant.saveProfile(profile, notebook: notebook) } label: {
                    Label(t("Guardar perfil", "Save profile"), systemImage: "checkmark").padding(.horizontal, 12).padding(.vertical, 9)
                        .modifier(NotebookInputSurface(radius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("notebook.saveProfile").disabled(profile == assistant.state(notebook).profile) }
            } else { history }
            if let error = assistant.error { Text(NotebookAssistantText.display(error, language: language)).foregroundStyle(.orange).font(.caption) }
        }.padding(24).frame(minWidth: 480, idealWidth: 700, maxWidth: 800, minHeight: 460, idealHeight: 620)
    }
    private func field(_ title: String, text: Binding<String>, lines: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextField(title, text: text, axis: .vertical).textFieldStyle(.plain).lineLimit(lines...8)
                .padding(12).modifier(NotebookInputSurface(radius: 12))
        }
    }
    private var history: some View {
        let checkpoints = assistant.store.timeline(notebook.id).reversed()
        let selected = checkpoints.first { $0.id == selection }
        return VStack(spacing: 12) {
            List(selection: $selection) {
                ForEach(Array(checkpoints)) { checkpoint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(checkpoint.summary).lineLimit(2)
                        Text(checkpoint.date, format: .dateTime.day().month().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(checkpoint.id)
                }
            }.frame(minHeight: 120, maxHeight: 190).accessibilityIdentifier("notebook.timeline")
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(selected.changedFiles, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(path).font(.callout.weight(.semibold))
                                ForEach(diff(selected, path: path)) { line in
                                    Text(line.prefix + " " + line.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .foregroundStyle(line.prefix == "+" ? Color.green : line.prefix == "−" ? Color.red : Color.secondary)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(maxHeight: .infinity)
                HStack {
                    Text(t("Restaurar conserva las versiones posteriores.", "Restoring preserves later versions.")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Restaurar", "Restore")) { model.restoreCheckpoint(selected) }
                        .disabled(assistant.runningNotebookID != nil || model.media?.isRecording == true)
                        .accessibilityIdentifier("notebook.restore")
                }
            } else { Text(t("Selecciona una versión para ver los cambios.", "Select a version to inspect changes.")).foregroundStyle(.secondary).frame(maxHeight: .infinity) }
        }
    }
    private func diff(_ checkpoint: NotebookCheckpoint, path: String) -> [DiffLine] {
        let timeline = assistant.store.timeline(notebook.id)
        let index = timeline.firstIndex { $0.id == checkpoint.id } ?? 0
        let before = index > 0 ? timeline[index - 1].files[path].flatMap { try? assistant.store.content($0) } ?? "" : ""
        let after = checkpoint.files[path].flatMap { try? assistant.store.content($0) } ?? ""
        return NoteDiff.lines(before: before, after: after).filter { $0.prefix != " " }
    }
}
