import SwiftUI
import LectureCore

/// The introduction's main action, in the app's accent colour.
struct OnboardingButtonStyle: ButtonStyle {
    @AppStorage("notes.accent") private var accent = ""
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 38)
            .background(NotebookAccent.color(accent), in: RoundedRectangle(cornerRadius: 10))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(enabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius: 10))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: Workbench
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.appearance") private var appearance = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: Int
    @State private var name = ""
    @State private var error: String?
    @FocusState private var naming: Bool
    init(model: Workbench, page: Int = 0) { self.model = model; _page = State(initialValue: page) }
    private static let pages = 4

    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            RadialGradient(colors: dark ? [Color(white: 0.16), Color(white: 0.05)] : [Color(white: 1), Color(white: 0.88)], center: .center, startRadius: 0, endRadius: 760)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(text("Saltar", "Skip")) { model.finishOnboarding() }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle()).modifier(ControlHoverBackground())
                        .accessibilityIdentifier("onboarding.skip")
                }.padding(.horizontal, 16).frame(height: 58).background(WindowDragRegion())
                Group {
                    switch page {
                    case 0: welcome
                    case 1: features
                    case 2: setup
                    default: firstNotebook
                    }
                }.frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity).id(page)
                    .transition(.opacity)
                footer.frame(height: 76).opacity(page == 0 ? 0 : 1).allowsHitTesting(page != 0)
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("onboarding")
    }

    private func go(_ next: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { page = min(max(next, 0), Self.pages - 1) }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            PalladiumMark(size: 176)
            Text("Palladium").font(.system(size: 46, weight: .medium)).tracking(-1.4).padding(.top, 18)
            Text(text("Un lugar tranquilo para tus apuntes.", "A calm place for your notes."))
                .font(.title3).foregroundStyle(.secondary).padding(.top, 10)
            Button(text("Empezar", "Get started")) { go(1) }.buttonStyle(OnboardingButtonStyle()).keyboardShortcut(.defaultAction)
                .padding(.top, 34).accessibilityIdentifier("onboarding.start")
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            PalladiumMark(size: 58).padding(.bottom, 6)
            Text(title).font(.system(size: 28, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Color(white: 0.13))
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [Color(white: 1), Color(white: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().strokeBorder(Color(white: 0.4).opacity(0.5), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var features: some View {
        VStack(spacing: 26) {
            heading(text("Todo en un cuaderno", "Everything in a notebook"), text("Notas, archivos y conversaciones sobre un mismo tema, juntos.", "Notes, files and conversations about one subject, together."))
            VStack(alignment: .leading, spacing: 18) {
                feature("book.closed", text("Cuadernos y Markdown", "Notebooks and Markdown"), text("Organiza notas en cuadernos y carpetas. Tablas, listas, fórmulas, imágenes, LaTeX y PDF.", "Organize notes into notebooks and folders. Tables, checklists, math, images, LaTeX and PDF."))
                feature("sparkles", text("Un asistente que conoce tu cuaderno", "An assistant that knows your notebook"), text("Chatea con Claude Code, Codex, Antigravity u OpenCode. Puede leer tus documentos, buscar en la web y editar notas.", "Chat with Claude Code, Codex, Antigravity or OpenCode. It can read your documents, search the web and edit notes."))
                feature("waveform", text("Dictado", "Dictation"), text("Habla en el chat con un modelo Whisper local o con la API de OpenAI.", "Speak into the chat with a local Whisper model or the OpenAI API."))
                feature("lock", text("Tus datos, en tu Mac", "Your data, on your Mac"), text("Notas y chats se guardan en local. Un proveedor solo recibe lo que necesita cada petición.", "Notes and chats are stored locally. A provider only receives what each request needs."))
            }.padding(20).modifier(NotebookInputSurface(radius: 16, borderOpacity: 0.25))
        }.padding(.horizontal, 24)
    }

    private static let providers: [NotesAIProvider] = [.claudeCode, .codexCLI, .antigravity, .openCode]
    private var setup: some View {
        VStack(spacing: 26) {
            heading(text("Hazlo tuyo", "Make it yours"), text("Puedes cambiarlo todo más tarde en Preferencias.", "You can change all of this later in Preferences."))
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(text("Apariencia", "Appearance")).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    NotebookSlidingSelector(selection: $appearance, options: [.init(id: "system", title: text("Sistema", "System")), .init(id: "light", title: text("Claro", "Light")), .init(id: "dark", title: text("Oscuro", "Dark"))])
                        .accessibilityLabel(text("Apariencia", "Appearance"))
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 12) {
                    Text(text("Asistente", "Assistant")).font(.system(size: 14, weight: .semibold))
                    ForEach(Self.providers, id: \.self) { provider in
                        let found = model.ai.map { FileManager.default.isExecutableFile(atPath: $0.providerSettings.configuration(for: provider).executablePath) } ?? false
                        HStack(spacing: 10) {
                            ProviderLogo(provider: provider, size: 20)
                            Text(provider.shortName).font(.callout)
                            Spacer()
                            Label(found ? text("Instalado", "Installed") : text("No encontrado", "Not found"), systemImage: found ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.caption).foregroundStyle(found ? .primary : .tertiary)
                        }
                    }
                    Text(text("Palladium usa las herramientas que ya tienes instaladas, con tu propia cuenta. No instala nada ni inicia sesión por ti.", "Palladium uses the tools you already have installed, with your own account. It installs nothing and never signs in for you."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20).modifier(NotebookInputSurface(radius: 16, borderOpacity: 0.25))
        }.padding(.horizontal, 24)
    }

    private var suggestions: [String] { language == "en" ? ["University", "Work", "Ideas"] : ["Universidad", "Trabajo", "Ideas"] }
    private var firstNotebook: some View {
        VStack(spacing: 26) {
            if model.activeNotebooks.isEmpty {
                heading(text("Crea tu primer cuaderno", "Create your first notebook"), text("Ponle el nombre de una asignatura, un proyecto o lo que quieras reunir.", "Name it after a course, a project, or whatever you want to gather."))
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 9) {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        TextField(text("Nombre del cuaderno", "Notebook name"), text: $name).textFieldStyle(.plain).font(.system(size: 15)).focused($naming)
                            .onSubmit(create).accessibilityIdentifier("onboarding.notebookName")
                    }.padding(13).modifier(NotebookInputSurface(radius: 12))
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion; naming = true }.buttonStyle(.plain).font(.callout)
                                .padding(.horizontal, 12).frame(height: 28).modifier(NotebookInputSurface(radius: 14))
                        }
                    }
                    if let error { Text(NotebookAssistantText.display(error, language: language)).font(.callout).foregroundStyle(.orange) }
                }.frame(maxWidth: 380).onAppear { naming = true }.onChange(of: name) { _, _ in error = nil }
            } else {
                heading(text("Todo listo", "You're all set"), text("Tus cuadernos te esperan en la barra lateral.", "Your notebooks are waiting in the sidebar."))
            }
        }.padding(.horizontal, 24)
    }

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try model.createNotebookItem(kind: "cuaderno", name: clean)
            model.notebookRevealRequest += 1
            model.finishOnboarding()
        } catch { self.error = error.localizedDescription }
    }

    private var footer: some View {
        let last = page == Self.pages - 1, creating = last && model.activeNotebooks.isEmpty
        return HStack {
            Button(text("Atrás", "Back")) { go(page - 1) }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle()).modifier(ControlHoverBackground())
            Spacer()
            if creating {
                Button(text("Ahora no", "Not now")) { model.finishOnboarding() }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle()).modifier(ControlHoverBackground())
                Button(text("Crear cuaderno", "Create notebook"), action: create).buttonStyle(OnboardingButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("onboarding.create")
            } else {
                Button(last ? text("Empezar", "Start") : text("Continuar", "Continue")) { if last { model.finishOnboarding() } else { go(page + 1) } }
                    .buttonStyle(OnboardingButtonStyle()).keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding.next")
            }
        }.padding(.horizontal, 28)
            .background {
                HStack(spacing: 7) {
                    ForEach(0..<Self.pages, id: \.self) { index in
                        Capsule().fill(Color.primary.opacity(index == page ? 0.75 : 0.18)).frame(width: index == page ? 18 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }
    }
}

/// What the workspace shows before any notebook exists.
struct NotebookEmptyLibrary: View {
    @ObservedObject var model: Workbench
    @AppStorage("notes.language") private var language = "es"
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private func hint(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
    }
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                PalladiumMark(size: 112)
                Text(text("Crea tu primer cuaderno", "Create your first notebook")).font(.system(size: 26, weight: .semibold)).padding(.top, 14)
                Text(text("Un cuaderno reúne las notas, los archivos y los chats de un mismo tema.", "A notebook gathers the notes, files and chats about one subject."))
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                Button { model.creationInitialName = ""; model.creationKind = "cuaderno" } label: {
                    Label(text("Nuevo cuaderno", "New notebook"), systemImage: "plus")
                }.buttonStyle(OnboardingButtonStyle()).disabled(!model.canManageFiles).padding(.top, 24).accessibilityIdentifier("empty.newNotebook")
                HStack(alignment: .top, spacing: 10) {
                    hint("text.alignleft", text("Escribe", "Write"), text("Notas en Markdown con tablas, fórmulas e imágenes.", "Markdown notes with tables, math and images."))
                    hint("sparkles", text("Pregunta", "Ask"), text("El asistente lee tu cuaderno y te ayuda a editarlo.", "The assistant reads your notebook and helps you edit it."))
                    hint("waveform", text("Dicta", "Dictate"), text("Habla en el chat y revisa el texto antes de enviarlo.", "Speak into the chat and review the text before sending."))
                }.padding(.top, 34)
                if !model.trash.isEmpty || model.notebooks.contains(where: { $0.archivedAt != nil }) {
                    Text(text("Hay elementos en la papelera que puedes restaurar.", "There are items in the trash you can restore."))
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 16)
                }
            }.frame(maxWidth: 560).padding(32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped().accessibilityIdentifier("empty.library")
    }
}
