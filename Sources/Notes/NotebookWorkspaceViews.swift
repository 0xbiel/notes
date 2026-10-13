import SwiftUI
import LectureCore
import UniformTypeIdentifiers

struct NotebookHome: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    @AppStorage("notes.language") private var language = "es"
    private var notebook: Notebook { model.currentNotebook }
    private var empty: Bool { assistant.isEmptyChat(notebook) }
    var body: some View {
        VStack(spacing: empty ? 18 : 0) {
            NotebookChatPicker(notebook: notebook, assistant: assistant)
                .padding(.top, empty ? 20 : 8).padding(.bottom, empty ? 0 : 6)
            if empty {
                Spacer(minLength: 20)
                VStack(spacing: 10) {
                    NotebookHomePicker(model: model, assistant: assistant)
                    Text(language == "en" ? "What would you like to work on?" : "¿En qué quieres trabajar?").foregroundStyle(.secondary)
                }
            } else {
                NotebookConversation(model: model, assistant: assistant, fullPage: true).frame(maxHeight: .infinity)
            }
            NotebookComposer(model: model, assistant: assistant, large: true).frame(maxWidth: 740)
                .padding(.top, empty ? 0 : 4).padding(.horizontal, empty ? 0 : 30)
            if empty { Spacer(minLength: 35) }
        }.padding(.horizontal, empty ? 30 : 0).padding(.bottom, empty ? 18 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

    }
}

struct ChatWorkingIndicator: View {
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.language") private var language = "es"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let color = NotebookAccent.color(accent)
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                Circle().stroke(color.opacity(0.16), lineWidth: 2)
                Circle().trim(from: 0.05, to: 0.8)
                    .stroke(AngularGradient(colors: [color.opacity(0.15), color.opacity(0.7), color], center: .center, startAngle: .degrees(18), endAngle: .degrees(288)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }.padding(1)
        }
        .frame(width: 16, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language == "en" ? "Working" : "Trabajando")
        .help(language == "en" ? "Working" : "Trabajando")
    }
}

struct NotebookHomePicker: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    var compact = false
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
            HStack(spacing: 10) {
                Text(model.currentNotebook.name)
                    .font(.system(size: compact ? 21 : 29, weight: .semibold, design: .rounded))
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
                if assistant.runningCount(in: model.currentNotebook) > 0 { ChatWorkingIndicator() }
            }
        }.buttonStyle(.plain)
            .onHover { titleHovered = $0 }
            .accessibilityIdentifier("notebook.homePicker")
            .accessibilityLabel(language == "en" ? "Choose notebook" : "Elegir cuaderno")
            .accessibilityValue(model.currentNotebook.name + (assistant.runningCount(in: model.currentNotebook) > 0 ? (language == "en" ? " · Working" : " · Trabajando") : ""))
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
                                    if model.openNotebookForNewChat(notebook.id) { presented = false }
                                } label: {
                                    notebookRowLabel(notebook)
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
    private func notebookRowLabel(_ notebook: Notebook) -> some View {
        let selected = model.selectedNotebookID == notebook.id
        let working = assistant.runningCount(in: notebook) > 0
        return HStack(spacing: 7) {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
            Text(notebook.name).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if working { ChatWorkingIndicator() }
            if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
        }.padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .modifier(SelectorRowBackground(highlighted: selected || hovered == notebook.id))
    }

}

struct NotebookChatPicker: View {
    let notebook: Notebook
    @ObservedObject var assistant: NotebookAssistantController
    var maximumTitleWidth: CGFloat = 240
    @AppStorage("notes.language") private var language = "es"
    @State private var presented = false
    @State private var hovered: String?
    @State private var search = ""
    @State private var pendingDeletion: NotebookChat?
    @AppStorage("notes.confirmChatDeletion") private var confirmChatDeletion = true
    private var chats: [NotebookChat] { assistant.matchingChats(notebook, query: search) }
    private var title: String { assistant.chat(notebook)?.title ?? "Chats" }
    private var titleWidth: CGFloat { min(maximumTitleWidth, max(28, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up))) }
    var body: some View {
        HStack(spacing: 12) {
            Button { presented.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                    Text(title).lineLimit(1).truncationMode(.tail).frame(width: titleWidth, alignment: .leading)
                    if assistant.runningCount(in: notebook) > 0 { ChatWorkingIndicator() }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.vertical, 8)
                    .modifier(NotebookInputSurface(radius: 7))
            }.buttonStyle(.plain)
                .accessibilityIdentifier("notebook.chatPicker")
                .accessibilityLabel(language == "en" ? "Choose chat" : "Elegir chat")
                .accessibilityValue((assistant.chat(notebook)?.title ?? "Chats") + (assistant.runningCount(in: notebook) > 0 ? (language == "en" ? " · \(assistant.runningCount(in: notebook)) working" : " · \(assistant.runningCount(in: notebook)) trabajando") : ""))
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
                                        chatRowLabel(chat)
                                    }.buttonStyle(.plain)
                                        .accessibilityAddTraits(assistant.chat(notebook)?.id == chat.id ? .isSelected : [])
                                        .accessibilityValue(assistant.isRunning(notebook, chatID: chat.id) ? (language == "en" ? "Working" : "Trabajando") : "")
                                        .accessibilityIdentifier("notebook.chat." + chat.id)
                                    Button {
                                        if confirmChatDeletion { pendingDeletion = chat }
                                        else {
                                            do { try assistant.deleteChat(chat.id, notebook: notebook) } catch { assistant.error = error.localizedDescription }
                                        }
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 26, height: 30)
                                    }.buttonStyle(.plain)
                                        .disabled(assistant.isRunning(notebook, chatID: chat.id))
                                        .accessibilityLabel((language == "en" ? "Delete chat: " : "Eliminar chat: ") + chat.title)
                                    }.modifier(SelectorRowBackground(highlighted: assistant.chat(notebook)?.id == chat.id || hovered == chat.id))
                                        .onHover { hovered = $0 ? chat.id : nil }
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
            } label: {
                Label(language == "en" ? "New chat" : "Nuevo chat", systemImage: "plus")
                    .padding(.horizontal, 10).frame(minWidth: 34, minHeight: 34)
                    .contentShape(Rectangle())
                    .modifier(ControlHoverBackground())
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("notebook.newChat")
        }.font(.callout)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain).accessibilityIdentifier("notebook.chatHeader")
    }
    private func chatRowLabel(_ chat: NotebookChat) -> some View {
        let selected = assistant.chat(notebook)?.id == chat.id
        let working = assistant.isRunning(notebook, chatID: chat.id)
        return HStack(spacing: 7) {
            Text(chat.title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if working { ChatWorkingIndicator() }
            if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
        }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

}

struct NotebookConversation: View {
    @State private var followsLatest = true
    @AppStorage("notes.language") private var language = "es"
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    var fullPage = false
    @State private var activeTurnID: String?
    @State private var visibleTurnIDs: Set<String> = []
    @State private var viewportHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var turns: [NotebookChatTurn] { NotebookChatTurn.collect(assistant.chat(model.currentNotebook)?.messages ?? []) }
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
                            .background {
                                if fullPage {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: NotebookChatMessageFrames.self, value: [message.id: geometry.frame(in: .named("notebook-conversation"))])
                                    }
                                }
                            }
                    }
                    if assistant.isRunning(model.currentNotebook) {
                        NotebookWorkLog(activities: assistant.activities(for: model.currentNotebook), running: true).padding(.vertical, 8)
                    }
                    if let error = assistant.unrepresentedError(model.currentNotebook) {
                        HStack(alignment: .top, spacing: 8) {
                            NotebookChatMarkdown(text: NotebookAssistantText.display(error, language: language)).foregroundStyle(.orange)
                            Button { assistant.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                .accessibilityLabel(language == "en" ? "Dismiss error" : "Cerrar error")
                        }.padding(4).accessibilityIdentifier("notebook.chatError")
                    }
                    Color.clear.frame(height: fullPage ? 48 : 1).id("end").onAppear { followsLatest = true }.onDisappear { followsLatest = false }
                }.frame(maxWidth: 740).frame(maxWidth: .infinity).padding(.horizontal, fullPage ? 56 : 8).padding(.top, fullPage ? 12 : 0)
            }
            .coordinateSpace(name: "notebook-conversation")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onPreferenceChange(NotebookChatMessageFrames.self) { frames in
                // Frames move on every scroll tick; the view only updates when the
                // turn in view changes, not on each of them.
                let turns = turns
                let visible = NotebookChatTurn.visible(in: frames, turns: turns, height: viewportHeight)
                if visible != visibleTurnIDs { visibleTurnIDs = visible }
                if let id = NotebookChatTurn.active(in: frames, turns: turns), id != activeTurnID { activeTurnID = id }
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .modifier(NotebookChatEdgeFade(enabled: fullPage))
            .overlay(alignment: .trailing) {
                if fullPage && turns.count > 1 {
                    NotebookChatNavigator(turns: turns, activeID: activeTurnID, visibleIDs: visibleTurnIDs) { id in
                        followsLatest = false
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                    }.padding(.trailing, 18)
                }
            }
            .onChange(of: assistant.chat(model.currentNotebook)?.id) { _, _ in
                activeTurnID = nil; visibleTurnIDs = []; followsLatest = true; proxy.scrollTo("end", anchor: .bottom)
            }
            .onChange(of: assistant.chat(model.currentNotebook)?.messages.count) { _, _ in if followsLatest { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: assistant.activities(for: model.currentNotebook).count) { _, _ in if followsLatest { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct NotebookChatEdgeFade: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                if enabled && !reduceTransparency {
                    let top = min(0.08, 12 / max(1, geometry.size.height))
                    let bottom = min(0.08, 22 / max(1, geometry.size.height))
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: top),
                        .init(color: .black, location: 1 - bottom),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                } else { Color.black }
            }
        }
    }
}

struct NotebookFloatingChat: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    let onClose: () -> Void
    @AppStorage("notes.language") private var language = "es"
    private var empty: Bool { assistant.isEmptyChat(model.currentNotebook) && !assistant.isRunning(model.currentNotebook) }
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                ZStack {
                    NotebookChatPicker(notebook: model.currentNotebook, assistant: assistant, maximumTitleWidth: min(240, max(28, geometry.size.width - 210)))
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 34)
                    HStack {
                        Button { model.expandNotebookChat() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 26, height: 26) }
                            .buttonStyle(.plain)
                            .help(language == "en" ? "Open full-page chat" : "Abrir chat a pantalla completa")
                            .accessibilityLabel(language == "en" ? "Open full-page chat" : "Abrir chat a pantalla completa")
                            .accessibilityIdentifier("notebook.expandChat")
                        Spacer(minLength: 0)
                        Button(action: onClose) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(language == "en" ? "Close chat" : "Cerrar chat")
                            .accessibilityIdentifier("notebook.closeChat")
                    }
                }
            }.frame(height: 38)
            if empty {
                VStack(spacing: 10) {
                    NotebookHomePicker(model: model, assistant: assistant, compact: true)
                    Text(language == "en" ? "What would you like to work on?" : "¿En qué quieres trabajar?")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("notebook.floatingChatWelcome")
            } else {
                NotebookConversation(model: model, assistant: assistant)
            }
        }.padding(14).frame(height: empty ? 180 : 280)
            .modifier(NotebookInputSurface(radius: 18, floating: true, opaque: true, borderOpacity: 0.6))
            .accessibilityIdentifier("notebook.floatingChat")
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
    private var running: Bool { assistant.isRunning(notebook) }
    var body: some View {
        VStack(spacing: 8) {
            if !assistant.queued(notebook).isEmpty {
                NotebookPromptQueue(model: model, assistant: assistant, notebook: notebook)
            }
            if !large && showConversation {
                NotebookFloatingChat(model: model, assistant: assistant, onClose: { showConversation = false })
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
                if let media = model.media { ChatDictationStatus(media: media) }
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
                    if let ai = model.ai { NotebookModelControls(ai: ai, disabled: running) { model.showPreferences = true } }
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
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(showConversation ? .isSelected : [])
                            .accessibilityIdentifier("notebook.showChat")
                    }
                    if running && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(assistant.chat(notebook)?.attachments ?? []).isEmpty) {
                        Menu {
                            Button(language == "en" ? "Queue after current request" : "Añadir a la cola") { model.submitNotebookPrompt() }
                            Button(language == "en" ? "Steer now" : "Cambiar instrucciones ahora") { model.steerNotebookPrompt() }
                        } label: { Image(systemName: "arrow.up").foregroundStyle(NotebookAccent.color(accent)).frame(width: 28, height: 28) }
                        .menuStyle(.borderlessButton).fixedSize().disabled(model.dictationActive).help(language == "en" ? "Queue or steer" : "Añadir a la cola o dirigir")
                    }
                    Button {
                        if running { assistant.stop(notebook: notebook) } else { model.submitNotebookPrompt() }
                    } label: {
                        Image(systemName: running ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(NotebookAccent.color(accent), in: Circle())
                    }.buttonStyle(.plain)
                        .disabled(!running && (model.dictationActive || (draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (assistant.chat(notebook)?.attachments ?? []).isEmpty) || assistant.importingAttachments))
                        .accessibilityLabel(running ? (language == "en" ? "Stop" : "Detener") : (language == "en" ? "Send" : "Enviar"))
                        .accessibilityIdentifier("notebook.send")
                }
            }.padding(large ? 18 : 12)
                .modifier(NotebookInputSurface(radius: large ? 22 : 18, floating: !large, opaque: !large, borderOpacity: 0.6))
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
        .onChange(of: notebook.id) { _, _ in
            showConversation = false
            if model.media?.isRecording == true { model.media?.stopMicrophone() }
        }
        .onChange(of: assistant.chat(notebook)?.id) { _, _ in
            if model.media?.isRecording == true { model.media?.stopMicrophone() }
        }
        .onChange(of: showConversation) { _, value in if !large { model.documentChatVisible = value } }
        .onAppear { if !large { model.documentChatVisible = showConversation } }
        .onDisappear { if !large { model.documentChatVisible = false } }
    }
}

private struct NotebookPromptQueue: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    let notebook: Notebook
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    @State private var editingID: String?
    @State private var editedText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                Text(language == "en" ? "Queued messages" : "Mensajes en cola").font(.caption.weight(.semibold))
                Spacer()
                if !assistant.isRunning(notebook) {
                    Button(language == "en" ? "Resume" : "Continuar") { model.resumeNotebookQueue() }.buttonStyle(.plain).foregroundStyle(NotebookAccent.color(accent))
                }
            }.foregroundStyle(.secondary)
            ForEach(assistant.queued(notebook)) { item in
                HStack(spacing: 8) {
                    if editingID == item.id {
                        TextField("", text: $editedText, axis: .vertical).textFieldStyle(.plain)
                        Button { assistant.updateQueued(notebook, id: item.id, text: editedText); editingID = nil } label: { Image(systemName: "checkmark") }
                        Button { editingID = nil } label: { Image(systemName: "xmark") }
                    } else {
                        Text(item.text.isEmpty ? (language == "en" ? "Attached files" : "Archivos adjuntos") : item.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Button { assistant.moveQueued(notebook, id: item.id, offset: -1) } label: { Image(systemName: "chevron.up") }.help(language == "en" ? "Move earlier" : "Mover antes")
                        Button { assistant.moveQueued(notebook, id: item.id, offset: 1) } label: { Image(systemName: "chevron.down") }.help(language == "en" ? "Move later" : "Mover después")
                        Button { editedText = item.text; editingID = item.id } label: { Image(systemName: "pencil") }.help(language == "en" ? "Edit" : "Editar")
                        Button { assistant.promoteQueued(notebook, id: item.id) } label: { Image(systemName: "arrow.up") }.help(language == "en" ? "Steer now" : "Cambiar instrucciones ahora")
                        Button { assistant.removeQueued(notebook, id: item.id) } label: { Image(systemName: "xmark") }.help(language == "en" ? "Remove" : "Eliminar")
                    }
                }.font(.caption).buttonStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(12).modifier(NotebookInputSurface(radius: 14, opaque: true))
    }
}

struct NotebookModelControls: View {
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
        if let selected = preferences.reasoningModel {
            AIReasoningSelector(levels: selected.reasoning, modelName: selected.name, fastMode: preferences.fastModeSelection, selection: preferences.reasoningSelection)
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
    @AppStorage("notes.accent") private var accent = ""
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
                        Toggle(t("Búsqueda web", "Web search"), isOn: Binding(get: { profile.allowsWebSearch }, set: { profile.webSearchEnabled = $0 }))
                            .modifier(NotebookToggleAccent(switchStyle: true))
                            .accessibilityIdentifier("notebook.profile.webSearch")
                        Text(t("Permite buscar fuentes actuales y descargar imágenes para este cuaderno.", "Allow searching current sources and downloading images for this notebook."))
                            .font(.caption).foregroundStyle(.secondary)
                        field(t("Propósito", "Purpose"), text: $profile.purpose)
                        field(t("Instrucciones del asistente", "Assistant instructions"), text: $profile.instructions, lines: 4)
                        field(t("Estilo y formato", "Style and formatting"), text: $profile.formatting)
                        field(t("Reglas de fuentes", "Source rules"), text: $profile.sourceRules)
                    }.padding(2)
                }
                HStack { Spacer(); Button { assistant.saveProfile(profile, notebook: notebook) } label: {
                    Label(t("Guardar perfil", "Save profile"), systemImage: "checkmark")
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(NotebookAccent.color(accent), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityIdentifier("notebook.saveProfile")
                    .disabled(profile == assistant.state(notebook).profile)
                    .opacity(profile == assistant.state(notebook).profile ? 0.45 : 1) }
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

/// Shared study control for Markdown and imported-source previews.
struct NotebookAssistantToggle: View {
    @ObservedObject var model: Workbench
    @AppStorage("notes.language") private var language = "es"
    private var title: String {
        language == "en" ? (model.hideStudyComposer ? "Show assistant" : "Hide assistant") :
            (model.hideStudyComposer ? "Mostrar asistente" : "Ocultar asistente")
    }
    var body: some View {
        Button { model.hideStudyComposer.toggle() } label: {
            Image(systemName: model.hideStudyComposer ? "bubble.left" : "bubble.left.fill")
                .frame(width: 34, height: 34).contentShape(Rectangle())
                .modifier(ControlHoverBackground())
        }.buttonStyle(.plain).help(title)
            .accessibilityLabel(title).accessibilityIdentifier("notebook.toggleAssistant")
    }
}

private struct ChatDictationStatus: View {
    @ObservedObject var media: MediaController
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        if media.isRecording || media.busy {
            Text(media.isRecording
                 ? (media.stopOnSilence
                    ? (language == "en" ? "Listening… Text appears after each phrase. Dictation stops when you stop speaking." : "Escuchando… El texto aparece tras cada frase. El dictado se detiene cuando dejas de hablar.")
                    : (language == "en" ? "Listening… Text appears after each phrase. Stop to review and send." : "Escuchando… El texto aparece tras cada frase. Detén el dictado para revisar y enviar."))
                 : (language == "en" ? "Finishing dictation…" : "Terminando dictado…"))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = media.error {
            HStack(alignment: .top) {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button { media.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .accessibilityLabel(language == "en" ? "Dismiss dictation error" : "Cerrar error de dictado")
            }
        }
    }
}
