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
            HStack {
                Text(text("Este Mac", "This Mac")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(text("Proveedor activo: ", "Active provider: ") + name(ai.providerSettings.selectedProvider)).font(.callout)
            }
            Group {
                if contentWidth >= 620 {
                    HStack(alignment: .top, spacing: 0) {
                        providerList.frame(width: 220)
                        Divider()
                        editor.padding(22).frame(width: contentWidth - 221)
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) { providerList; Divider(); editor.padding(20) }
                }
            }
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
            Text(text("Cada lote conserva su proveedor y su permiso de edición. Ajusta los cambios automáticos en General.", "Each batch keeps its provider and editing permission. Set automatic changes in General."))
                .font(.caption).foregroundStyle(.secondary)
        }
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
        VStack(spacing: 0) {
            ForEach(NotesAIProvider.allCases) { provider in
                HStack(spacing: 8) {
                    Button {
                        preferences.draft.selectedProvider = provider
                        showRuntime = false
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ProviderLogo(provider: provider, size: 17)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(name(provider)).font(.callout.weight(.medium)).lineLimit(1)
                                Text(status(provider)).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(name(provider))
                        .accessibilityAddTraits(preferences.draft.selectedProvider == provider ? .isSelected : [])
                        .accessibilityIdentifier("provider.select." + provider.rawValue)
                    Toggle(name(provider), isOn: enabledBinding(provider))
                        .controlSize(.mini).labelsHidden().modifier(NotebookToggleAccent(switchStyle: true))
                        .accessibilityLabel(text("Activar ", "Enable ") + name(provider))
                        .accessibilityIdentifier("provider.enabled." + provider.rawValue)
                }.padding(.horizontal, 12).padding(.vertical, 16)
                    .background {
                        Rectangle().fill(preferences.draft.selectedProvider == provider ? Color.primary.opacity(0.06) : .clear)
                    }
                if provider != NotesAIProvider.allCases.last { Divider().opacity(0.5) }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                ProviderLogo(provider: preferences.draft.selectedProvider, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(preferences.draft.selectedProvider)).font(.title3.weight(.semibold))
                    Text(status(preferences.draft.selectedProvider)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    checkTask = Task { await preferences.checkInstallation() }
                } label: {
                    if preferences.checking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.help(text("Actualizar estado y modelos", "Refresh status and models"))
                    .accessibilityLabel(text("Actualizar estado y modelos", "Refresh status and models"))
                    .accessibilityIdentifier("provider.check")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(text("Configuración", "Setup")).font(.headline)
                Text(accountProvider ? text("Usa tu cuenta iniciada en el cliente del proveedor.", "Use your account signed in through the provider's client.") : text("OpenRouter · router gratuito · retención cero para apuntes reales.", "OpenRouter · free router · zero retention for real notes."))
                    .font(.callout).foregroundStyle(.secondary)
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
                    Button(text("Detectar instalación", "Detect installation")) { preferences.detectInstallation() }
                    Text(text("Utiliza una instalación existente. Palladium no instala programas ni copia credenciales.", "Uses an existing installation. Palladium does not install software or copy credentials."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.headline)
            ProviderModelList(preferences: preferences)
            Divider()
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
            })).font(.callout).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}
