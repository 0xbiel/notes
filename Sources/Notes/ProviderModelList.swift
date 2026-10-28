import SwiftUI
import LectureCore

struct ProviderModelList: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    @State private var query = ""
    @State private var customID = ""
    @State private var showCustom = false
    @State private var refreshTask: Task<Void, Never>?
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private func text(_ spanish: String, _ english: String) -> String { language == "en" ? english : spanish }
    private var rows: [AIProviderModel] {
        preferences.models.filter { query.isEmpty || ($0.name + " " + $0.id).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("Modelos", "Models")).font(.headline)
                Text("\(preferences.models.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { refreshTask = Task { await preferences.checkInstallation() } } label: {
                    if preferences.checkingProvider == preferences.draft.selectedProvider { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) }
                }.buttonStyle(.plain).frame(width: 28, height: 28).modifier(ControlHoverBackground())
                    .disabled(preferences.checking || !ProviderRuntime.isInstalled(preferences.draft.selected) || !preferences.draft.selected.accountSendingAllowed)
                    .help(text("Actualizar modelos", "Refresh models")).accessibilityLabel(text("Actualizar modelos", "Refresh models"))
                    .accessibilityIdentifier("provider.check")
            }
            if preferences.draft.selectedProvider != .openCode {
                Button { preferences.selectModel("default") } label: {
                    Label(text("Predeterminado de la cuenta", "Account default"), systemImage: preferences.draft.selected.model == "default" ? "checkmark.circle.fill" : "circle")
                        .font(.callout)
                }.buttonStyle(.plain).accessibilityIdentifier("provider.model.default")
            }
            if let chosen = preferences.reasoningModel {
                AIReasoningSelector(levels: chosen.reasoning, modelName: chosen.name, fastMode: preferences.fastModeSelection, selection: preferences.reasoningSelection)
                    .accessibilityIdentifier("provider.reasoning")
            }
            if !preferences.models.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(text("Buscar modelos…", "Search models…"), text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(text("Limpiar búsqueda", "Clear search"))
                    }
                }.padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                    .accessibilityIdentifier("provider.models.search")
                VStack(spacing: 0) {
                    ForEach(rows) { model in
                        modelRow(model)
                        if model.id != rows.last?.id { Divider().opacity(0.4) }
                    }
                    if rows.isEmpty { Text(text("No hay modelos coincidentes", "No matching models")).font(.callout).foregroundStyle(.secondary).padding(12) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .modifier(NotebookInputSurface(radius: 10, borderOpacity: 0.18))
            } else if !preferences.checking {
                Text(ProviderRuntime.isInstalled(preferences.draft.selected) ? text("Actualiza para cargar los modelos disponibles.", "Refresh to load available models.") : text("Configura el proveedor para cargar sus modelos.", "Set up the provider to load its models.")).font(.callout).foregroundStyle(.secondary)
            }
            if preferences.draft.selectedProvider.supportsCustomModels {
                DisclosureGroup(text("Añadir modelo personalizado", "Add custom model"), isExpanded: $showCustom) {
                    HStack {
                        TextField(text("Identificador del modelo", "Model identifier"), text: $customID).textFieldStyle(.plain)
                            .padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                            .accessibilityIdentifier("provider.custom-model")
                        Button {
                            preferences.addCustomModel(customID.trimmingCharacters(in: .whitespacesAndNewlines))
                            if preferences.error == nil { customID = "" }
                        } label: {
                            Text(text("Añadir", "Add")).font(.callout.weight(.medium))
                                .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 34)
                                .background(NotebookAccent.color(accent), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.top, 8)
                }.font(.callout)
            }
            Text(text("Marca favoritos, oculta modelos o cambia su orden.", "Favorite, hide, or reorder models."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: preferences.draft.selectedProvider) { _, _ in query = ""; customID = ""; showCustom = false }
    }

    private func modelRow(_ model: AIProviderModel) -> some View {
        let selected = preferences.draft.selected.model == model.id
        let favorite = preferences.modelPreferences.favorites.contains(model.id)
        let hidden = preferences.modelPreferences.hidden.contains(model.id)
        return HStack(alignment: .top, spacing: 10) {
            Button { preferences.selectModel(model.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? NotebookAccent.color(accent) : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text(model.id).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(hidden)
                .accessibilityLabel(text("Elegir ", "Select ") + model.name).accessibilityIdentifier("provider.model." + model.id)
                .help(model.detail)
            Button { preferences.favorite(model.id) } label: {
                Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? NotebookAccent.color(accent) : .secondary)
            }.buttonStyle(.plain).frame(width: 26, height: 26).modifier(ControlHoverBackground()).help(text("Favorito", "Favorite"))
                .accessibilityLabel(text("Favorito ", "Favorite ") + model.name)
            Button { preferences.hide(model.id) } label: { Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                .buttonStyle(.plain).frame(width: 26, height: 26).modifier(ControlHoverBackground()).disabled(selected).help(text("Mostrar u ocultar", "Show or hide"))
                .accessibilityLabel(text("Visibilidad ", "Visibility ") + model.name)
            Menu {
                Button(text("Mover arriba", "Move up")) { preferences.move(model.id, offset: -1) }
                Button(text("Mover abajo", "Move down")) { preferences.move(model.id, offset: 1) }
                if preferences.modelPreferences.custom.contains(where: { $0.id == model.id }) {
                    Button(text("Eliminar modelo personalizado", "Remove custom model")) { preferences.removeCustomModel(model.id) }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(text("Opciones de ", "Options for ") + model.name)
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(NotebookAccent.color(accent).opacity(selected ? 0.08 : 0))
            .opacity(hidden ? 0.55 : 1)
    }
}
