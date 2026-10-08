import SwiftUI
import LectureCore

@MainActor
final class ProviderPreferencesModel: ObservableObject {
    @Published var draft: AIProviderSettings
    @Published private(set) var checking = false
    @Published private(set) var diagnostic: String?
    @Published private(set) var error: String?
    @Published private(set) var checks: [NotesAIProvider: Bool] = [:]
    @Published private(set) var catalogs: [NotesAIProvider: [AIProviderModel]] = [:]
    let ai: AIController

    init(ai: AIController) { self.ai = ai; draft = ai.providerSettings }
    var hasChanges: Bool { draft != ai.providerSettings }

    func detectInstallation() {
        let detected = AIProviderSettings().configuration(for: draft.selectedProvider)
        draft.selected.executablePath = detected.executablePath
        draft.selected.homePath = detected.homePath
        draft.selected.harnessPath = detected.harnessPath
        draft.selected.accountSendingAllowed = false
        invalidateSelection()
    }

    func clearStatus() { diagnostic = nil; error = nil }
    func invalidateSelection() { checks.removeValue(forKey: draft.selectedProvider); catalogs.removeValue(forKey: draft.selectedProvider); clearStatus() }

    var modelPreferences: AIProviderModelPreferences {
        get { draft.modelPreferences?[draft.selectedProvider.rawValue] ?? .init() }
        set {
            var values = draft.modelPreferences ?? [:]
            values[draft.selectedProvider.rawValue] = newValue
            draft.modelPreferences = values
        }
    }

    var models: [AIProviderModel] {
        let known = catalogs[draft.selectedProvider] ?? []
        let custom = modelPreferences.custom.filter { entry in !known.contains(where: { $0.id == entry.id }) }
        let options = modelPreferences
        func group(_ identifier: String) -> Int { options.favorites.contains(identifier) ? 0 : options.hidden.contains(identifier) ? 2 : 1 }
        return (known + custom).sorted {
            let left = group($0.id), right = group($1.id)
            if left != right { return left < right }
            let leftIndex = options.order.firstIndex(of: $0.id) ?? Int.max
            let rightIndex = options.order.firstIndex(of: $1.id) ?? Int.max
            return leftIndex == rightIndex ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : leftIndex < rightIndex
        }
    }

    func selectModel(_ identifier: String) { draft.selected.model = identifier; draft.selected.reasoningEffort = nil }
    func favorite(_ identifier: String) {
        var options = modelPreferences
        if options.favorites.contains(identifier) { options.favorites.removeAll { $0 == identifier } }
        else { options.favorites.append(identifier); options.hidden.removeAll { $0 == identifier } }
        modelPreferences = options
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

    func checkInstallation() async {
        guard !checking, !ai.running else { return }
        checking = true; clearStatus()
        let configuration = draft.selected
        defer { checking = false }
        do {
            let result = try await ai.transport.diagnose(configuration)
            if draft.selected == configuration { diagnostic = result.message; checks[configuration.provider] = true }
            let models = try await ai.transport.models(configuration)
            if draft.selected == configuration { catalogs[configuration.provider] = models }
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
    @State private var contentWidth: CGFloat = 680
    @AppStorage("notes.language") private var language = "es"

    init(ai: AIController) {
        self.ai = ai
        _preferences = StateObject(wrappedValue: ProviderPreferencesModel(ai: ai))
    }

    private func text(_ spanish: String, _ english: String) -> String { language == "en" ? english : spanish }
    private var accountProvider: Bool { preferences.draft.selectedProvider != .openCode }
    private var busy: Bool { preferences.checking || ai.running }
    private func name(_ provider: NotesAIProvider) -> String {
        switch provider { case .openCode: "OpenCode"; case .codexCLI: "Codex CLI"; case .antigravity: "Antigravity" }
    }
    private func status(_ provider: NotesAIProvider) -> String {
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
                        providerList.frame(width: 180)
                        Divider()
                        editor.padding(22).frame(width: contentWidth - 181)
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) { providerList; Divider(); editor.padding(20) }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
            Text(text("Cada lote pendiente conserva su proveedor. Las propuestas se revisan antes de modificar una nota.", "Pending batches keep their provider. Review each proposal before it changes a note."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(busy)
        .onChange(of: preferences.draft) { _, _ in preferences.clearStatus() }
        .task(id: preferences.draft.selectedProvider) {
            if preferences.catalogs[preferences.draft.selectedProvider] == nil { await preferences.checkInstallation() }
        }
        .onDisappear { checkTask?.cancel() }
    }

    private var providerList: some View {
        VStack(spacing: 4) {
            ForEach(NotesAIProvider.allCases) { provider in
                Button {
                    preferences.draft.selectedProvider = provider
                    showRuntime = false
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        ProviderLogo(provider: provider)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name(provider)).font(.callout.weight(.medium))
                            HStack(spacing: 5) {
                                Circle().fill(preferences.checks[provider] == true ? Color.green : preferences.checks[provider] == false ? .orange : .secondary).frame(width: 5, height: 5)
                                Text(status(provider)).font(.caption2).foregroundStyle(.secondary)
                            }
                            if ai.providerSettings.selectedProvider == provider {
                                Text(text("En uso", "Active")).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(preferences.draft.selectedProvider == provider ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(name(provider))
                    .accessibilityAddTraits(preferences.draft.selectedProvider == provider ? .isSelected : [])
                    .accessibilityIdentifier("provider.select." + provider.rawValue)
            }
        }.padding(8)
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
                    Toggle(text("Permitir envíos con esta cuenta", "Allow sending with this account"), isOn: $preferences.draft.selected.accountSendingAllowed)
                        .font(.callout).accessibilityIdentifier("provider.consent")
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
                    Text(text("Utiliza una instalación existente. Notes no instala programas ni copia credenciales.", "Uses an existing installation. Notes does not install software or copy credentials."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.headline)
            ProviderModelList(preferences: preferences)
            Divider()
            HStack {
                Button(text("Descartar", "Discard")) { preferences.discard() }.disabled(!preferences.hasChanges)
                Spacer()
                Button(ai.providerSettings.selectedProvider == preferences.draft.selectedProvider ? text("Guardar cambios", "Save changes") : text("Usar proveedor", "Use provider")) { preferences.save() }
                    .buttonStyle(.borderedProminent).disabled(!preferences.hasChanges).accessibilityIdentifier("provider.save")
            }
            Text(preferences.hasChanges ? text("Cambios sin guardar", "Unsaved changes") : text("Configuración guardada", "Settings saved"))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("provider.saved-status")
            if let diagnostic = preferences.diagnostic {
                Label(diagnostic, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("provider.diagnostic")
            }
            if let error = preferences.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("provider.error")
            }
            Text(text("El catálogo se consulta con tu sesión existente, sin enviar notas. La disponibilidad puede variar según la cuota de tu cuenta.", "The catalog uses your existing sign-in without sending notes. Availability may vary with your account quota."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: String, value: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(get: { value.wrappedValue }, set: { updated in
                value.wrappedValue = updated
                preferences.invalidateSelection()
                if identifier != "provider.model" { preferences.draft.selected.accountSendingAllowed = false }
            })).font(.callout).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}
