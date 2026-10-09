import SwiftUI
import LectureCore

struct GeneralAIPreferences: View {
    @ObservedObject var ai: AIController
    @StateObject private var preferences: ProviderPreferencesModel
    @State private var connectionTask: Task<Void, Never>?
    let manageProviders: () -> Void
    @AppStorage("notes.language") private var language = "es"
    init(ai: AIController, manageProviders: @escaping () -> Void) {
        self.ai = ai; self.manageProviders = manageProviders
        _preferences = StateObject(wrappedValue: ProviderPreferencesModel(ai: ai))
    }
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(text("Inteligencia artificial", "Artificial intelligence")).font(.headline)
                Spacer()
                Button(action: manageProviders) { Image(systemName: "gearshape") }
                    .help(text("Gestionar proveedores y modelos", "Manage providers and models"))
                    .accessibilityLabel(text("Gestionar proveedores", "Manage providers"))
            }
            Text(text("En uso: ", "In use: ") + ai.providerSettings.selectedProvider.title + " · " + ai.providerSettings.selected.model)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        modelControl.fixedSize()
                        Spacer(minLength: 8)
                        permissionsControl.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        modelControl
                        permissionsControl
                    }
                }
                HStack(spacing: 8) { thinkingControl; fastControl }
            }.padding(18).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button {
                    connectionTask = Task { await preferences.testConnection() }
                } label: { Label(text("Probar conexión", "Test connection"), systemImage: "bolt.horizontal.circle") }
                    .disabled(preferences.testingConnection)
                    .accessibilityIdentifier("general.ai.test")
                Button(text("Actualizar modelos", "Refresh models")) { Task { await preferences.checkInstallation() } }
                    .accessibilityIdentifier("general.ai.refresh")
                if preferences.checking { ProgressView().controlSize(.small) }
                Spacer()
            }
            if preferences.testingConnection {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(text("Verificando respuesta del modelo…", "Checking model response…")).font(.caption)
                    Button(text("Cancelar", "Cancel")) { connectionTask?.cancel() }.font(.caption)
                }
            } else if preferences.connectionResultIsCurrent, let result = preferences.connectionResult {
                Label(text("Conexión verificada", "Connection verified") + " · " + result.model + " · " + String(format: "%.1f s", result.elapsedSeconds), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).accessibilityIdentifier("general.ai.test.success")
            } else if preferences.connectionResultIsCurrent, let error = preferences.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("general.ai.test.error")
            }
            if let error = preferences.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .onChange(of: preferences.draft) { _, _ in
            if preferences.hasChanges { preferences.save() }
        }
        .onChange(of: ai.providerSettings) { old, updated in
            if preferences.draft == old { preferences.draft = updated }
        }
        .disabled(ai.running)
        .task(id: preferences.catalogIdentity) { await preferences.refreshCatalogPeriodically() }
        .onDisappear { connectionTask?.cancel() }
    }
    private var modelControl: some View { AIModelSelector(preferences: preferences, manageProviders: manageProviders) }
    @ViewBuilder private var thinkingControl: some View {
        if preferences.draft.selectedProvider == .codexCLI, let selected = preferences.selectedModel, !selected.reasoning.isEmpty {
            AIOptionSelector(title: text("Razonamiento", "Reasoning"), symbol: "brain", options:
                [.init(id: "auto", title: "Auto")] + selected.reasoning.map { effort in
                    .init(id: effort, title: effort == "xhigh" ? text("Extra alto", "Extra High") : effort.capitalized,
                          badge: effort == selected.defaultReasoningEffort ? text("Predeterminado", "Default") : nil)
                }, selection: Binding(get: { preferences.draft.selected.reasoningEffort ?? "auto" }, set: { preferences.draft.selected.reasoningEffort = $0 == "auto" ? nil : $0 }))
                .accessibilityIdentifier("general.ai.thinking")
        }
    }
    @ViewBuilder private var fastControl: some View {
        if preferences.supportsFastMode {
            AIOptionSelector(title: text("Velocidad", "Speed"), symbol: "bolt", options: [
                .init(id: "standard", title: text("Estándar", "Standard")), .init(id: "fast", title: "Fast")
            ], selection: Binding(get: { preferences.draft.selected.fastMode == true ? "fast" : "standard" }, set: { preferences.draft.selected.fastMode = $0 == "fast" }))
                .accessibilityIdentifier("general.ai.fast")
                .help(text("Modo rápido: mayor consumo de créditos", "Fast mode: higher credit usage"))
        }
    }
    private var permissionsControl: some View {
        AIOptionSelector(title: text("Permisos", "Permissions"), symbol: "lock.open", options: [
            .init(id: "review", title: text("Revisar todo", "Review everything")),
            .init(id: "additions", title: text("Solo añadir", "Add only")),
            .init(id: "edits", title: text("Editar texto", "Edit text"))
        ], selection: Binding(get: { (preferences.draft.editAutonomy ?? .review).rawValue }, set: { preferences.draft.editAutonomy = AIEditAutonomy(rawValue: $0) }))
            .accessibilityIdentifier("general.ai.autonomy")
    }
}
