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
    @Published private(set) var versions: [NotesAIProvider: String] = [:]
    /// Keychain entries known to exist, as "provider/name"; values are never held here.
    @Published private(set) var storedSecrets: Set<String> = []
    var readSecret: (NotesAIProvider, String) throws -> String? = { try ProviderSecrets.read($0, $1) }
    var writeSecret: (String, NotesAIProvider, String) throws -> Void = { try ProviderSecrets.save($0, provider: $1, name: $2) }
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
    func invalidateSelection() {
        checks.removeValue(forKey: draft.selectedProvider); versions.removeValue(forKey: draft.selectedProvider)
        synchronizeCatalogs(); clearStatus()
    }

    // MARK: Instance environment and secrets

    /// A text binding for an optional setting; clearing the field removes it.
    func option(_ keyPath: WritableKeyPath<AIProviderConfiguration, String?>) -> Binding<String> {
        Binding(get: { self.draft.selected[keyPath: keyPath] ?? "" }, set: { self.draft.selected[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func secretKey(_ name: String) -> String { draft.selectedProvider.rawValue + "/" + name }
    func hasSecret(_ name: String) -> Bool { storedSecrets.contains(secretKey(name)) }
    /// Looks up which secrets exist for the selected provider.
    func refreshSecrets() {
        let provider = draft.selectedProvider
        var names = (draft.selected.environment ?? []).filter(\.sensitive).map { ProviderSecrets.environmentName($0.name) }
        if provider == .antigravity { names.append(ProviderSecrets.antigravityAPIKey) }
        for name in names {
            if ((try? readSecret(provider, name)) ?? nil)?.isEmpty == false { storedSecrets.insert(secretKey(name)) }
            else { storedSecrets.remove(secretKey(name)) }
        }
    }
    func saveSecret(_ value: String, name: String) {
        clearStatus()
        do {
            try writeSecret(value, draft.selectedProvider, name)
            if value.isEmpty { storedSecrets.remove(secretKey(name)) } else { storedSecrets.insert(secretKey(name)) }
        } catch { self.error = error.localizedDescription }
    }
    func addVariable(name: String, value: String, sensitive: Bool) -> Bool {
        clearStatus()
        do {
            var variables = draft.selected.environment ?? []
            guard !variables.contains(where: { $0.name == name }) else { throw MediaError.invalid("Esa variable ya existe.") }
            variables.append(.init(name: name, value: sensitive ? "" : value, sensitive: sensitive))
            try ProviderEnvironment.validate(variables)
            if sensitive {
                guard !value.isEmpty else { throw MediaError.invalid("Introduce el valor sensible de " + name + ".") }
                try writeSecret(value, draft.selectedProvider, ProviderSecrets.environmentName(name))
                storedSecrets.insert(secretKey(ProviderSecrets.environmentName(name)))
            }
            draft.selected.environment = variables
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setVariable(_ name: String, value: String) {
        guard var variables = draft.selected.environment, let index = variables.firstIndex(where: { $0.name == name }) else { return }
        if variables[index].sensitive { saveSecret(value, name: ProviderSecrets.environmentName(name)); return }
        variables[index].value = value
        draft.selected.environment = variables
    }
    func removeVariable(_ name: String) {
        guard var variables = draft.selected.environment, let index = variables.firstIndex(where: { $0.name == name }) else { return }
        if variables[index].sensitive { saveSecret("", name: ProviderSecrets.environmentName(name)) }
        variables.remove(at: index)
        draft.selected.environment = variables.isEmpty ? nil : variables
    }

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
    var supportsFastMode: Bool { draft.selectedProvider.supportsReasoning && selectedModel?.supportsFastMode == true }
    /// The selected model's reasoning levels, for providers that publish them.
    var reasoningModel: AIProviderModel? {
        guard draft.selectedProvider.supportsReasoning, let model = selectedModel, !model.reasoning.isEmpty else { return nil }
        return model
    }
    var reasoningSelection: Binding<String> {
        Binding(get: { self.draft.selected.reasoningEffort ?? "auto" }, set: { self.draft.selected.reasoningEffort = $0 == "auto" ? nil : $0 })
    }
    var fastModeSelection: Binding<Bool>? {
        supportsFastMode ? Binding(get: { self.draft.selected.fastMode == true }, set: { self.draft.selected.fastMode = $0 }) : nil
    }
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
            guard draft.selectedProvider.supportsCustomModels else { throw MediaError.invalid("Selecciona uno de los modelos disponibles de este proveedor.") }
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
            if draft.selected == configuration { diagnostic = result.message; checks[configuration.provider] = true; versions[configuration.provider] = result.version }
            _ = try await ai.modelCatalogs.refresh(configuration, force: true)
            if draft.selected == configuration {
                if configuration.provider.supportsReasoning, selectedModel != nil {
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
    @State private var showEnvironment = false
    @State private var hovered: NotesAIProvider?
    let contentWidth: CGFloat
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""

    init(ai: AIController, contentWidth: CGFloat = 680) {
        self.ai = ai
        self.contentWidth = contentWidth
        _preferences = StateObject(wrappedValue: ProviderPreferencesModel(ai: ai))
    }

    private func text(_ spanish: String, _ english: String) -> String { language == "en" ? english : spanish }
    private var selectedProvider: NotesAIProvider { preferences.draft.selectedProvider }
    private var accountProvider: Bool { selectedProvider != .openCode }
    private var busy: Bool { preferences.checking || ai.running }
    private func name(_ provider: NotesAIProvider) -> String { preferences.draft.configuration(for: provider).name }
    private func status(_ provider: NotesAIProvider) -> String {
        if !preferences.draft.configuration(for: provider).accountSendingAllowed { return text("Desactivado", "Disabled") }
        if preferences.checking, selectedProvider == provider { return text("Comprobando…", "Checking…") }
        guard let passed = preferences.checks[provider] else { return text("Sin comprobar", "Not checked") }
        return passed ? text("Instalación verificada", "Installation verified") : text("Requiere atención", "Needs attention")
    }
    private func statusColor(_ provider: NotesAIProvider) -> Color {
        guard preferences.draft.configuration(for: provider).accountSendingAllowed, let passed = preferences.checks[provider] else { return Color.secondary.opacity(0.45) }
        return passed ? .green : .orange
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
        .onChange(of: selectedProvider, initial: true) { _, _ in preferences.refreshSecrets() }
        .task(id: preferences.catalogIdentity) { await preferences.refreshCatalogPeriodically() }
        .onDisappear { checkTask?.cancel() }
    }

    /// One full-width row per provider, so the list keeps its proportions as
    /// providers are added.
    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(NotesAIProvider.allCases) { provider in
                providerRow(provider)
                if provider != NotesAIProvider.allCases.last { Divider().opacity(0.4).padding(.leading, 48) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .modifier(NotebookInputSurface(radius: 12, borderOpacity: 0.18))
    }

    private func providerRow(_ provider: NotesAIProvider) -> some View {
        let selected = selectedProvider == provider
        let configuration = preferences.draft.configuration(for: provider)
        return HStack(spacing: 12) {
            Button {
                preferences.draft.selectedProvider = provider
                showRuntime = false; showEnvironment = false
            } label: {
                HStack(spacing: 12) {
                    ProviderLogo(provider: provider, size: 22, accent: configuration.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(name(provider)).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            if let version = preferences.versions[provider] {
                                Text(version).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        HStack(spacing: 5) {
                            Circle().fill(statusColor(provider)).frame(width: 6, height: 6)
                            Text(status(provider)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(name(provider))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("provider.select." + provider.rawValue)
            Toggle(name(provider), isOn: $preferences.draft[provider].accountSendingAllowed)
                .controlSize(.mini).labelsHidden().modifier(NotebookToggleAccent(switchStyle: true))
                .accessibilityLabel(text("Activar ", "Enable ") + name(provider))
                .accessibilityIdentifier("provider.enabled." + provider.rawValue)
        }.padding(.horizontal, 14)
            .background(selected ? NotebookAccent.color(accent).opacity(0.10) : Color.primary.opacity(hovered == provider ? 0.04 : 0))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(NotebookAccent.color(accent)).frame(width: 3, height: 24).padding(.leading, 4) }
            }
            .opacity(configuration.accountSendingAllowed || selected ? 1 : 0.6)
            .onHover { hovered = $0 ? provider : (hovered == provider ? nil : hovered) }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProviderLogo(provider: selectedProvider, size: 28, accent: preferences.draft.selected.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(selectedProvider)).font(.title3.weight(.semibold))
                    Text(preferences.diagnostic ?? status(selectedProvider)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
            ProviderIdentityFields(preferences: preferences)
            DisclosureGroup(text("Instalación", "Runtime"), isExpanded: $showRuntime) {
                ProviderRuntimeFields(preferences: preferences).padding(.top, 12)
            }.font(.callout.weight(.medium))
            DisclosureGroup(text("Entorno", "Environment"), isExpanded: $showEnvironment) {
                ProviderEnvironmentFields(preferences: preferences).padding(.top, 12)
            }.font(.callout.weight(.medium))
            Divider().opacity(0.35)
            ProviderModelList(preferences: preferences)
            if let error = preferences.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("provider.error")
            }
        }
    }
}
