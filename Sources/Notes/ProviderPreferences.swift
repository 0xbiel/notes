import SwiftUI
import Combine
import LectureCore

@MainActor
final class ProviderPreferencesModel: ObservableObject {
    @Published var draft: AIProviderSettings { didSet { synchronizeCatalogs(); invalidateRuntimePaths() } }
    @Published private(set) var checking = false
    @Published private(set) var checkingProvider: NotesAIProvider?
    @Published private(set) var diagnostic: String?
    @Published private(set) var error: String?
    @Published var checks: [NotesAIProvider: Bool] = [:]
    @Published var versions: [NotesAIProvider: String] = [:]
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

    @Published var runtimeStates: [NotesAIProvider: ProviderRuntimeState] = [:]
    @Published var runtimeProvider: NotesAIProvider?
    var runtimeBusy: Bool { runtimeProvider != nil }
    var runtimeTask: Task<Void, Never>?
    var fetchLatestVersion: @MainActor (NotesAIProvider) async throws -> String = { try await ProviderRuntime.shared.latestVersion($0) }
    var performRuntimeInstall: @MainActor (NotesAIProvider, @escaping @Sendable (ProviderInstallStage) -> Void) async throws -> String = {
        try await ProviderRuntime.shared.install($0, progress: $1)
    }

    func detectInstallation() {
        clearStatus()
        guard let binary = ProviderRuntime.detectedExecutable(for: draft.selected) else {
            error = "No se encontró una instalación compatible. Selecciona su ejecutable o usa la descarga de Palladium cuando esté disponible."
            return
        }
        draft.selected.executablePath = binary
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
    var connectionTestProvider: NotesAIProvider? { testingConnection ? testedConfiguration?.provider : nil }
    func testConnection() async {
        guard !testingConnection, !ai.running else { return }
        let configuration = draft.selected
        testedConfiguration = configuration
        testingConnection = true; connectionResult = nil; connectionError = nil
        defer { testingConnection = false }
        do { connectionResult = try await ProviderConnectionTest.run(configuration) }
        catch is CancellationError { connectionError = "Prueba cancelada." }
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
        // Opening Preferences must leave setup under the visible download controls.
        guard ProviderRuntime.isInstalled(draft.selected), draft.selected.accountSendingAllowed else { return }
        repeat {
            guard !Task.isCancelled else { return }
            do { _ = try await ai.modelCatalogs.refresh(draft.selected) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            do { try await Task.sleep(for: .seconds(ProviderCatalogStore.refreshInterval)) }
            catch { return }
        } while !Task.isCancelled
    }

    func checkInstallation() async {
        guard !checking, !runtimeBusy, !ai.running else { return }
        checking = true; clearStatus()
        let configuration = draft.selected
        checkingProvider = configuration.provider
        defer { checking = false; checkingProvider = nil }
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
    @State private var showRuntime = false
    @State private var showEnvironment = false
    @State private var showIdentity = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var hovered: NotesAIProvider?
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""

    init(ai: AIController) {
        self.ai = ai
        _preferences = StateObject(wrappedValue: ProviderPreferencesModel(ai: ai))
    }

    private func text(_ spanish: String, _ english: String) -> String { language == "en" ? english : spanish }
    private var selectedProvider: NotesAIProvider { preferences.draft.selectedProvider }
    private var accountProvider: Bool { selectedProvider != .openCode }
    private var busy: Bool { preferences.checking || preferences.runtimeBusy || preferences.testingConnection || ai.running }
    private func name(_ provider: NotesAIProvider) -> String { preferences.draft.configuration(for: provider).name }
    private func status(_ provider: NotesAIProvider) -> String {
        if !preferences.draft.configuration(for: provider).accountSendingAllowed { return text("Desactivado", "Disabled") }
        if preferences.checkingProvider == provider { return text("Actualizando modelos…", "Refreshing models…") }
        if preferences.connectionTestProvider == provider { return text("Probando conexión…", "Testing connection…") }
        let configuration = preferences.draft[provider]
        let runtime = preferences.runtimeState(for: provider)
        if case .checkingUpdates = runtime.operation { return text("Buscando actualizaciones…", "Checking for updates…") }
        if runtime.operation != nil { return text("Preparando…", "Preparing…") }
        if runtime.error != nil { return text("Requiere atención", "Needs attention") }
        guard ProviderRuntime.isInstalled(configuration) else {
            return ProviderRuntime.isManaged(configuration) && ProviderRuntime.supportsInstallation(provider)
                ? text("Disponible para descargar", "Ready to download") : text("Selecciona una instalación", "Choose an installation")
        }
        if preferences.updateAvailable(for: provider) { return text("Actualización disponible", "Update available") }
        if preferences.checks[provider] == false { return text("Requiere atención", "Needs attention") }
        return ProviderRuntime.isManaged(configuration) ? text("Instalado en Palladium", "Installed in Palladium") : text("Instalación propia", "Custom installation")
    }
    private func statusColor(_ provider: NotesAIProvider) -> Color {
        guard preferences.draft[provider].accountSendingAllowed else { return .secondary.opacity(0.45) }
        if preferences.runtimeState(for: provider).error != nil || preferences.checks[provider] == false { return .orange }
        if preferences.updateAvailable(for: provider) { return NotebookAccent.color(accent) }
        return ProviderRuntime.isInstalled(preferences.draft[provider]) ? .green : .secondary.opacity(0.45)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 680
            let sidebarWidth: CGFloat = compact ? 68 : min(232, max(190, geometry.size.width * 0.24))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    if !compact {
                        HStack {
                            Text(text("Proveedores", "Providers")).font(.caption.weight(.medium))
                            Spacer()
                            Text("\(NotesAIProvider.allCases.count)").font(.caption2.monospacedDigit())
                        }.foregroundStyle(.secondary).padding(.horizontal, 10)
                    }
                    ScrollView {
                        providerList(compact: compact)
                    }.scrollIndicators(.hidden)
                    if !compact {
                        Text(text("Los cambios se guardan automáticamente.", "Changes are saved automatically."))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
                    }
                }.padding(.horizontal, compact ? 8 : 12).padding(.vertical, 20)
                    .frame(width: sidebarWidth)
                    .accessibilityIdentifier("provider.sidebar")
                Divider().opacity(0.4)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            editor
                            Text(text("Cada lote conserva su proveedor y su permiso de edición. Ajusta los cambios automáticos en General.", "Each batch keeps its provider and editing permission. Set automatic changes in General."))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(compact ? 20 : 28)
                            .frame(maxWidth: 736, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id("provider-settings-top")
                    }.accessibilityIdentifier("provider.settings")
                        .onChange(of: selectedProvider) { _, _ in scroll.scrollTo("provider-settings-top", anchor: .top) }
                }
            }
        }
        .tint(NotebookAccent.color(accent))
        .onChange(of: preferences.draft) { _, _ in
            if preferences.hasChanges { preferences.save() }
        }
        .onChange(of: ai.providerSettings) { old, updated in
            if preferences.draft == old { preferences.draft = updated }
        }
        .onChange(of: selectedProvider, initial: true) { _, _ in preferences.refreshSecrets() }
        .task(id: preferences.catalogIdentity) { await preferences.refreshCatalogPeriodically() }
        .onDisappear { connectionTask?.cancel(); preferences.cancelRuntimeOperation() }
    }

    private func providerList(compact: Bool) -> some View {
        VStack(spacing: 6) {
            ForEach(NotesAIProvider.allCases) { provider in
                providerRow(provider, compact: compact)
            }
        }
    }

    private func providerRow(_ provider: NotesAIProvider, compact: Bool) -> some View {
        let selected = selectedProvider == provider
        let configuration = preferences.draft.configuration(for: provider)
        let working = preferences.runtimeState(for: provider).operation != nil || preferences.checkingProvider == provider || preferences.connectionTestProvider == provider
        return Button {
            preferences.draft.selectedProvider = provider
            showRuntime = false; showEnvironment = false; showIdentity = false
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    ProviderLogo(provider: provider, size: 24, accent: configuration.accentColor)
                    if compact {
                        Circle().fill(statusColor(provider)).frame(width: 6, height: 6).offset(x: 2, y: 2)
                    }
                }.frame(width: 26, height: 26)
                if !compact {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name(provider)).font(.callout.weight(selected ? .semibold : .medium)).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(statusColor(provider)).frame(width: 5, height: 5)
                            Text(status(provider)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if working { ProgressView().controlSize(.mini) }
                }
            }.padding(.horizontal, compact ? 12 : 10).frame(maxWidth: .infinity).frame(height: 60)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .background(selected ? NotebookAccent.color(accent).opacity(0.10) : Color.primary.opacity(hovered == provider ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(NotebookAccent.color(accent)).frame(width: 3, height: 22) }
            }
            .opacity(configuration.accountSendingAllowed || selected ? 1 : 0.6)
            .onHover { hovered = $0 ? provider : (hovered == provider ? nil : hovered) }
            .help(name(provider) + " · " + status(provider))
            .accessibilityLabel(name(provider)).accessibilityValue(status(provider))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("provider.select." + provider.rawValue)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProviderLogo(provider: selectedProvider, size: 28, accent: preferences.draft.selected.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name(selectedProvider)).font(.title2.weight(.semibold))
                        if let version = preferences.installedVersion(for: selectedProvider) {
                            Text(version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(status(selectedProvider)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle(text("Activado", "Enabled"), isOn: $preferences.draft[selectedProvider].accountSendingAllowed)
                    .labelsHidden().controlSize(.small).modifier(NotebookToggleAccent(switchStyle: true))
                    .disabled(busy).help(text("Activar ", "Enable ") + name(selectedProvider))
                    .accessibilityLabel(text("Activar ", "Enable ") + name(selectedProvider))
                    .accessibilityIdentifier("provider.enabled." + selectedProvider.rawValue)
            }
            ProviderInstallationView(preferences: preferences) { showRuntime = true }
            accountDetails
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 14) {
                ProviderModelList(preferences: preferences)
                connectionControls
            }.disabled(busy)
            if preferences.connectionTestProvider == selectedProvider {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text("Verificando la respuesta…", "Checking the response…")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(text("Cancelar", "Cancel")) { connectionTask?.cancel() }.buttonStyle(.plain).font(.caption)
                }
            }
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 14) {
                DisclosureGroup(text("Cuenta y ajustes avanzados", "Account & advanced settings"), isExpanded: $showRuntime) {
                    ProviderRuntimeFields(preferences: preferences).padding(.top, 12)
                }
                DisclosureGroup(text("Variables de entorno", "Environment variables"), isExpanded: $showEnvironment) {
                    ProviderEnvironmentFields(preferences: preferences).padding(.top, 12)
                }
                DisclosureGroup(text("Personalizar nombre y color", "Customize name & color"), isExpanded: $showIdentity) {
                    ProviderIdentityFields(preferences: preferences).padding(.top, 12)
                }
            }.font(.callout.weight(.medium)).disabled(busy)
            if let error = preferences.error {
                Label(NotebookAssistantText.display(error, language: language), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("provider.error")
            }
        }
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if accountProvider {
                Text(text("Usa tu inicio de sesión o la conexión configurada en el proveedor. El audio permanece en tu Mac; el texto enviado sigue las condiciones de tu cuenta.", "Uses your existing sign-in or provider connection. Audio stays on your Mac; sent text follows your account's terms."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(text("Permitir retención para el chat del cuaderno", "Allow provider retention for notebook chat"), isOn: Binding(
                    get: { preferences.draft.openCode.openRouterAllowRetention == true },
                    set: { preferences.draft.openCode.openRouterAllowRetention = $0 }
                )).modifier(NotebookToggleAccent()).accessibilityIdentifier("provider.openrouter.retention").disabled(busy)
                Text(text("Precio cero y entrenamiento prohibido. Al activar la retención, los proveedores pueden conservar el contexto enviado. Las transcripciones siguen exigiendo retención cero.", "Free routing with training prohibited. Enabling retention lets providers keep sent context. Transcription batches still require zero retention."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                connectionTask = Task { await preferences.testConnection() }
            } label: {
                Label(text("Probar conexión", "Test connection"), systemImage: "bolt.horizontal.circle")
                    .font(.callout).foregroundStyle(NotebookAccent.color(accent))
                    .padding(.horizontal, 10).frame(height: 32).modifier(NotebookInputSurface(radius: 8))
            }.buttonStyle(.plain).disabled(!ProviderRuntime.isInstalled(preferences.draft.selected) || !preferences.draft.selected.accountSendingAllowed)
                .help(text("Envía un mensaje breve de prueba al modelo seleccionado.", "Sends a short test message to the selected model."))
                .accessibilityIdentifier("provider.test-connection")
            if preferences.connectionResultIsCurrent, let result = preferences.connectionResult {
                Label(text("Conexión verificada", "Connection verified") + String(format: " · %.1f s", result.elapsedSeconds), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            } else if preferences.connectionResultIsCurrent, let error = preferences.connectionError {
                Label(NotebookAssistantText.display(error, language: language), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
}
