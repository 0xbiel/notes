import SwiftUI
import Combine
import LectureCore

@MainActor
final class ProviderPreferencesModel: ObservableObject {
    @Published var draft: AIProviderSettings { didSet { synchronizeCatalogs() } }
    @Published private(set) var checking = false
    @Published private(set) var diagnostic: String?
    @Published private(set) var error: String?
    @Published private(set) var checks: [NotesAIProvider: Bool] = [:]
    @Published private(set) var catalogs: [NotesAIProvider: [AIProviderModel]] = [:]
    @Published private(set) var testingConnection = false
    @Published private(set) var connectionResult: ProviderConnectionTestResult?
    @Published private(set) var connectionError: String?
    private var testedConfiguration: AIProviderConfiguration?
    private var catalogSubscription: AnyCancellable?
    let ai: AIController

    init(ai: AIController) {
        self.ai = ai; draft = ai.providerSettings
        synchronizeCatalogs()
        catalogSubscription = ai.modelCatalogs.$entries.sink { [weak self] entries in
            self?.synchronizeCatalogs(entries)
        }
    }
    private func synchronizeCatalogs(_ entries: [NotesAIProvider: ProviderCatalogStore.Entry]? = nil) {
        let entries = entries ?? ai.modelCatalogs.entries
        let matching = entries.filter { $0.value.key == ProviderCatalogKey(draft.configuration(for: $0.key)) }.mapValues(\.models)
        if catalogs != matching { catalogs = matching }
    }
    struct CatalogIdentity: Hashable { let key: ProviderCatalogKey; let enabled: Bool }
    var catalogIdentity: CatalogIdentity { .init(key: ProviderCatalogKey(draft.selected), enabled: draft.selected.accountSendingAllowed) }
    var hasChanges: Bool { draft != ai.providerSettings }

    func detectInstallation() {
        let detected = AIProviderSettings().configuration(for: draft.selectedProvider)
        draft.selected.executablePath = detected.executablePath
        draft.selected.homePath = detected.homePath
        draft.selected.harnessPath = detected.harnessPath
        invalidateSelection()
    }

    func clearStatus() { diagnostic = nil; error = nil }
    func invalidateSelection() { checks.removeValue(forKey: draft.selectedProvider); synchronizeCatalogs(); clearStatus() }

    var modelPreferences: AIProviderModelPreferences {
        get { draft.modelPreferences?[draft.selectedProvider.rawValue] ?? .init() }
        set {
            var values = draft.modelPreferences ?? [:]
            values[draft.selectedProvider.rawValue] = newValue
            draft.modelPreferences = values
        }
    }

    var models: [AIProviderModel] { models(for: draft.selectedProvider) }

    func models(for provider: NotesAIProvider) -> [AIProviderModel] {
        let known = catalogs[provider] ?? []
        let options = draft.modelPreferences?[provider.rawValue] ?? .init()
        let custom = options.custom.filter { entry in !known.contains(where: { $0.id == entry.id }) }
        func group(_ identifier: String) -> Int { options.favorites.contains(identifier) ? 0 : options.hidden.contains(identifier) ? 2 : 1 }
        return (known + custom).sorted {
            let left = group($0.id), right = group($1.id)
            if left != right { return left < right }
            let leftIndex = options.order.firstIndex(of: $0.id) ?? Int.max
            let rightIndex = options.order.firstIndex(of: $1.id) ?? Int.max
            return leftIndex == rightIndex ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : leftIndex < rightIndex
        }
    }

    var selectedModel: AIProviderModel? {
        if draft.selected.model == "default" { return models.first(where: \.isDefault) }
        return models.first { $0.id == draft.selected.model }
    }
    var supportsFastMode: Bool { draft.selectedProvider == .codexCLI && selectedModel?.supportsFastMode == true }
    func selectModel(_ identifier: String) {
        draft.selected.model = identifier; draft.selected.reasoningEffort = nil
        draft.selected.fastMode = false
    }
    func favorite(_ identifier: String) {
        favorite(identifier, provider: draft.selectedProvider)
    }
    func favorite(_ identifier: String, provider: NotesAIProvider) {
        var options = draft.modelPreferences?[provider.rawValue] ?? .init()
        if options.favorites.contains(identifier) { options.favorites.removeAll { $0 == identifier } }
        else { options.favorites.append(identifier); options.hidden.removeAll { $0 == identifier } }
        var values = draft.modelPreferences ?? [:]
        values[provider.rawValue] = options
        draft.modelPreferences = values
    }
    func hide(_ identifier: String) {
        guard identifier != draft.selected.model else { return }
        var options = modelPreferences
        if options.hidden.contains(identifier) { options.hidden.removeAll { $0 == identifier } }
        else { options.hidden.append(identifier); options.favorites.removeAll { $0 == identifier } }
        modelPreferences = options
    }
    func move(_ identifier: String, offset: Int) {
        var order = models.map(\.id)
        guard let index = order.firstIndex(of: identifier), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        modelPreferences.order = order
    }
    func addCustomModel(_ identifier: String) {
        clearStatus()
        do {
            guard draft.selectedProvider == .codexCLI else { throw MediaError.invalid("Selecciona uno de los modelos disponibles de este proveedor.") }
            try ProviderModelCatalog.validateID(identifier)
            guard identifier != "default", !models.contains(where: { $0.id == identifier }) else { throw MediaError.invalid("Ese modelo ya está disponible.") }
            modelPreferences.custom.append(.init(id: identifier, name: identifier))
            selectModel(identifier)
        } catch { self.error = error.localizedDescription }
    }
    func removeCustomModel(_ identifier: String) {
        var options = modelPreferences
        options.custom.removeAll { $0.id == identifier }; options.favorites.removeAll { $0 == identifier }
        options.hidden.removeAll { $0 == identifier }; options.order.removeAll { $0 == identifier }
        modelPreferences = options
        if draft.selected.model == identifier { selectModel("default") }
    }

    func save() {
        clearStatus()
        do { try ai.saveProviderSettings(draft) }
        catch { self.error = error.localizedDescription }
    }

    func discard() { draft = ai.providerSettings; clearStatus() }

    var connectionResultIsCurrent: Bool { testedConfiguration == draft.selected }
    func testConnection() async {
        guard !testingConnection, !ai.running else { return }
        let configuration = draft.selected
        testedConfiguration = configuration
        testingConnection = true; connectionResult = nil; connectionError = nil
        defer { testingConnection = false }
        do { connectionResult = try await ProviderConnectionTest.run(configuration) }
        catch is CancellationError { connectionError = "Prueba cancelada / Test cancelled" }
        catch { connectionError = error.localizedDescription }
    }

    func loadCatalogs() async {
        for provider in NotesAIProvider.allCases where draft.configuration(for: provider).accountSendingAllowed {
            guard !Task.isCancelled else { return }
            let configuration = draft.configuration(for: provider)
            do {
                _ = try await ai.modelCatalogs.refresh(configuration)
            } catch { }
        }
    }

    func refreshCatalogPeriodically() async {
        repeat {
            guard !Task.isCancelled else { return }
            do { _ = try await ai.modelCatalogs.refresh(draft.selected) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            do { try await Task.sleep(for: .seconds(ProviderCatalogStore.refreshInterval)) }
            catch { return }
        } while !Task.isCancelled
    }

    func checkInstallation() async {
        guard !checking, !ai.running else { return }
        checking = true; clearStatus()
        let configuration = draft.selected
        defer { checking = false }
        do {
            let result = try await ai.transport.diagnose(configuration)
            if draft.selected == configuration { diagnostic = result.message; checks[configuration.provider] = true }
            _ = try await ai.modelCatalogs.refresh(configuration, force: true)
            if draft.selected == configuration {
                if configuration.provider == .codexCLI, selectedModel != nil {
                    if !supportsFastMode { draft.selected.fastMode = false }
                    if let effort = draft.selected.reasoningEffort, selectedModel?.reasoning.contains(effort) != true { draft.selected.reasoningEffort = nil }
                }
            }
        } catch {
            if draft.selected == configuration { self.error = error.localizedDescription; checks[configuration.provider] = false }
        }
    }
}

struct ProviderPreferences: View {
    @ObservedObject var ai: AIController
    @StateObject private var preferences: ProviderPreferencesModel
    @State private var checkTask: Task<Void, Never>?
    @State private var showRuntime = false
    let contentWidth: CGFloat
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""

    init(ai: AIController, contentWidth: CGFloat = 680) {
        self.ai = ai
        self.contentWidth = contentWidth
        _preferences = StateObject(wrappedValue: ProviderPreferencesModel(ai: ai))
    }

    private func text(_ spanish: String, _ english: String) -> String { language == "en" ? english : spanish }
    private var accountProvider: Bool { preferences.draft.selectedProvider != .openCode }
    private var busy: Bool { preferences.checking || ai.running }
    private func name(_ provider: NotesAIProvider) -> String {
        switch provider { case .openCode: "OpenCode"; case .codexCLI: "Codex CLI"; case .antigravity: "Antigravity" }
    }
    private func status(_ provider: NotesAIProvider) -> String {
        if !preferences.draft.configuration(for: provider).accountSendingAllowed { return text("Desactivado", "Disabled") }
        if preferences.checking, preferences.draft.selectedProvider == provider { return text("Comprobando…", "Checking…") }
        guard let passed = preferences.checks[provider] else { return text("Sin comprobar", "Not checked") }
        return passed ? text("Instalación verificada", "Installation verified") : text("Requiere atención", "Needs attention")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            providerList
            editor.padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
            Text(text("Cada lote conserva su proveedor y su permiso de edición. Ajusta los cambios automáticos en General.", "Each batch keeps its provider and editing permission. Set automatic changes in General."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .tint(NotebookAccent.color(accent))
        .disabled(busy)
        .onChange(of: preferences.draft) { _, _ in
            if preferences.hasChanges { preferences.save() }
        }
        .onChange(of: ai.providerSettings) { old, updated in
            if preferences.draft == old { preferences.draft = updated }
        }
        .task(id: preferences.catalogIdentity) { await preferences.refreshCatalogPeriodically() }
        .onDisappear { checkTask?.cancel() }
    }

    private func enabledBinding(_ provider: NotesAIProvider) -> Binding<Bool> {
        Binding(get: { preferences.draft.configuration(for: provider).accountSendingAllowed }, set: { enabled in
            switch provider {
            case .openCode: preferences.draft.openCode.accountSendingAllowed = enabled
            case .codexCLI: preferences.draft.codexCLI.accountSendingAllowed = enabled
            case .antigravity: preferences.draft.antigravity.accountSendingAllowed = enabled
            }
        })
    }

    private var providerList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: contentWidth >= 620 ? 190 : 240), spacing: 8)], spacing: 8) {
            ForEach(NotesAIProvider.allCases) { provider in
                let selected = preferences.draft.selectedProvider == provider
                HStack(spacing: 8) {
                    Button {
                        preferences.draft.selectedProvider = provider
                        showRuntime = false
                    } label: {
                        HStack(spacing: 10) {
                            ProviderLogo(provider: provider, size: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name(provider)).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text(status(provider)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(name(provider))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("provider.select." + provider.rawValue)
                    Toggle(name(provider), isOn: enabledBinding(provider))
                        .controlSize(.mini).labelsHidden().modifier(NotebookToggleAccent(switchStyle: true))
                        .accessibilityLabel(text("Activar ", "Enable ") + name(provider))
                        .accessibilityIdentifier("provider.enabled." + provider.rawValue)
                }.padding(12).frame(minHeight: 56)
                    .background(NotebookAccent.color(accent).opacity(selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 12))
                    .modifier(NotebookInputSurface(radius: 12, borderOpacity: 0.18))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NotebookAccent.color(accent).opacity(selected ? 0.5 : 0), lineWidth: 1))
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProviderLogo(provider: preferences.draft.selectedProvider, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(preferences.draft.selectedProvider)).font(.title3.weight(.semibold))
                    Text(status(preferences.draft.selectedProvider)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    checkTask = Task { await preferences.checkInstallation() }
                } label: {
                    if preferences.checking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) }
                }.buttonStyle(.plain).frame(width: 32, height: 32).modifier(ControlHoverBackground()).help(text("Actualizar estado y modelos", "Refresh status and models"))
                    .accessibilityLabel(text("Actualizar estado y modelos", "Refresh status and models"))
                    .accessibilityIdentifier("provider.check")
            }
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 8) {
                Text(accountProvider ? text("Usa tu cuenta iniciada en el cliente del proveedor.", "Use your account signed in through the provider's client.") : text("OpenRouter · router gratuito · entrenamiento prohibido.", "OpenRouter · free router · training prohibited."))
                    .font(.callout).foregroundStyle(.secondary)
                if !accountProvider {
                    Toggle(text("Permitir retención para el chat del cuaderno", "Allow provider retention for notebook chat"), isOn: Binding(
                        get: { preferences.draft.openCode.openRouterAllowRetention == true },
                        set: { preferences.draft.openCode.openRouterAllowRetention = $0 }
                    )).modifier(NotebookToggleAccent()).accessibilityIdentifier("provider.openrouter.retention")
                    Text(text("Los proveedores gratuitos pueden conservar las peticiones y el contexto enviado. Se prohíbe el entrenamiento y se mantiene el precio cero. Las transcripciones siguen exigiendo retención cero.", "Free providers may retain prompts and sent note context. Training remains prohibited and the price stays zero. Transcription batches still require zero retention."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if accountProvider {
                    Text(text("Se envían fragmentos y contexto limitado. Se aplican los costes y la retención de tu cuenta; el audio permanece local.", "Selected text and limited context are sent. Account costs and retention apply; audio stays local."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(text("Instalación", "Runtime"), isExpanded: $showRuntime) {
                VStack(alignment: .leading, spacing: 14) {
                    field(text("Ejecutable", "Executable"), value: $preferences.draft.selected.executablePath, identifier: "provider.executable")
                    if accountProvider {
                        field(text("Carpeta del perfil", "Profile folder"), value: $preferences.draft.selected.homePath, identifier: "provider.profile")
                    }
                    if preferences.draft.selectedProvider == .antigravity {
                        field("localharness_external", value: $preferences.draft.selected.harnessPath, identifier: "provider.harness")
                    }
                    Button { preferences.detectInstallation() } label: {
                        Label(text("Detectar instalación", "Detect installation"), systemImage: "magnifyingglass")
                            .font(.callout).padding(.horizontal, 10).frame(height: 32)
                            .modifier(NotebookInputSurface(radius: 8))
                    }.buttonStyle(.plain)
                    Text(text("Utiliza una instalación existente. Palladium no instala programas ni copia credenciales.", "Uses an existing installation. Palladium does not install software or copy credentials."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.callout.weight(.medium))
            Divider().opacity(0.35)
            ProviderModelList(preferences: preferences)
            if let error = preferences.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("provider.error")
            }
        }
    }

    private func field(_ title: String, value: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(get: { value.wrappedValue }, set: { updated in
                value.wrappedValue = updated
                preferences.invalidateSelection()
            })).font(.callout).textFieldStyle(.plain)
                .padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}
