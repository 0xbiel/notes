import SwiftUI
import LectureCore

struct GeneralAIPreferences: View {
    @ObservedObject var ai: AIController
    @StateObject private var preferences: ProviderPreferencesModel
    @State private var connectionTask: Task<Void, Never>?
    let manageProviders: () -> Void
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
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
                Button(action: manageProviders) {
                    Image(systemName: "gearshape").font(.system(size: 13))
                        .foregroundStyle(.secondary).frame(width: 30, height: 30)
                        .modifier(ControlHoverBackground())
                }.buttonStyle(.plain)
                    .help(text("Gestionar proveedores y modelos", "Manage providers and models"))
                    .accessibilityLabel(text("Gestionar proveedores", "Manage providers"))
            }
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        modelControl.fixedSize()
                        thinkingControl.fixedSize()
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        modelControl
                        thinkingControl
                    }
                }
                Divider().opacity(0.35)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(text("Permiso de edición", "Editing permission"))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        permissionsControl.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text("Permiso de edición", "Editing permission"))
                            .font(.callout).foregroundStyle(.secondary)
                        permissionsControl
                    }
                }
            }.padding(16).modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
            HStack {
                Button {
                    connectionTask = Task { await preferences.testConnection() }
                } label: {
                    Label(text("Probar conexión", "Test connection"), systemImage: "bolt.horizontal.circle")
                        .font(.callout.weight(.medium)).foregroundStyle(NotebookAccent.color(accent))
                        .padding(.horizontal, 12).frame(height: 34)
                        .modifier(NotebookInputSurface(radius: 9))
                }.buttonStyle(.plain)
                    .disabled(preferences.testingConnection)
                    .accessibilityIdentifier("general.ai.test")
                Button { Task { await preferences.checkInstallation() } } label: {
                    Label(text("Actualizar modelos", "Refresh models"), systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(height: 34)
                        .modifier(ControlHoverBackground())
                }.buttonStyle(.plain)
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
                Label([text("Conexión verificada", "Connection verified"), result.model, String(format: "%.1f s", result.elapsedSeconds)].joined(separator: " · "), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).accessibilityIdentifier("general.ai.test.success")
            } else if preferences.connectionResultIsCurrent, let error = preferences.connectionError {
                Label(NotebookAssistantText.display(error, language: language), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .accessibilityIdentifier("general.ai.test.error")
            }
            if let error = preferences.error { Text(NotebookAssistantText.display(error, language: language)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .onChange(of: preferences.draft) { _, _ in
            if preferences.hasChanges { preferences.save() }
        }
        .onChange(of: ai.providerSettings) { old, updated in
            if preferences.draft == old { preferences.draft = updated }
        }
        .tint(NotebookAccent.color(accent))
        .disabled(ai.running)
        .task(id: preferences.catalogIdentity) { await preferences.refreshCatalogPeriodically() }
        .onDisappear { connectionTask?.cancel() }
    }
    private var modelControl: some View { AIModelSelector(preferences: preferences, manageProviders: manageProviders) }
    @ViewBuilder private var thinkingControl: some View {
        if let selected = preferences.reasoningModel {
            AIReasoningSelector(levels: selected.reasoning, modelName: selected.name, fastMode: preferences.fastModeSelection, selection: preferences.reasoningSelection)
                .accessibilityIdentifier("general.ai.thinking")
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
