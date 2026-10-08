import SwiftUI
import LectureCore

struct ProviderModelList: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    @State private var query = ""
    @State private var customID = ""
    @State private var showCustom = false
    @AppStorage("notes.language") private var language = "es"
    private func text(_ spanish: String, _ english: String) -> String { language == "en" ? english : spanish }
    private var rows: [AIProviderModel] {
        preferences.models.filter { query.isEmpty || ($0.name + " " + $0.id).localizedCaseInsensitiveContains(query) }
    }
    private var chosen: AIProviderModel? { preferences.models.first { $0.id == preferences.draft.selected.model } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("Modelos", "Models")).font(.headline)
                Text("\(preferences.models.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if preferences.checking { ProgressView().controlSize(.small) }
            }
            if preferences.draft.selectedProvider != .openCode {
                Button { preferences.selectModel("default") } label: {
                    Label(text("Predeterminado de la cuenta", "Account default"), systemImage: preferences.draft.selected.model == "default" ? "checkmark.circle.fill" : "circle")
                        .font(.callout)
                }.buttonStyle(.plain).accessibilityIdentifier("provider.model.default")
            }
            if !preferences.models.isEmpty {
                TextField(text("Buscar modelos…", "Search models…"), text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider.models.search")
                VStack(spacing: 0) {
                    ForEach(rows) { model in
                        modelRow(model)
                        if model.id != rows.last?.id { Divider().opacity(0.4) }
                    }
                    if rows.isEmpty { Text(text("No hay modelos coincidentes", "No matching models")).font(.callout).foregroundStyle(.secondary).padding(12) }
                }
                .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.3)))
            } else if !preferences.checking {
                Text(text("Actualiza para cargar los modelos disponibles.", "Refresh to load available models.")).font(.callout).foregroundStyle(.secondary)
            }
            if let chosen, preferences.draft.selectedProvider == .codexCLI, !chosen.reasoning.isEmpty {
                Picker(text("Razonamiento", "Reasoning"), selection: $preferences.draft.selected.reasoningEffort) {
                    Text(text("Predeterminado", "Default")).tag(String?.none)
                    ForEach(chosen.reasoning, id: \.self) { effort in Text(effort.capitalized).tag(Optional(effort)) }
                }.font(.callout).accessibilityIdentifier("provider.reasoning")
            }
            if preferences.draft.selectedProvider == .codexCLI {
                DisclosureGroup(text("Añadir modelo personalizado", "Add custom model"), isExpanded: $showCustom) {
                    HStack {
                        TextField(text("Identificador del modelo", "Model identifier"), text: $customID).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("provider.custom-model")
                        Button(text("Añadir", "Add")) {
                            preferences.addCustomModel(customID.trimmingCharacters(in: .whitespacesAndNewlines))
                            if preferences.error == nil { customID = "" }
                        }.disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.top, 8)
                }.font(.callout)
            }
            Text(text("Marca favoritos, oculta modelos o cambia su orden. Guarda los cambios para conservar tus preferencias.", "Favorite, hide, or reorder models. Save changes to keep your preferences."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: preferences.draft.selectedProvider) { _, _ in query = ""; customID = ""; showCustom = false }
    }

    private func modelRow(_ model: AIProviderModel) -> some View {
        let selected = preferences.draft.selected.model == model.id
        let favorite = preferences.modelPreferences.favorites.contains(model.id)
        let hidden = preferences.modelPreferences.hidden.contains(model.id)
        return HStack(alignment: .top, spacing: 10) {
            Button { preferences.selectModel(model.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text(model.id).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        if !model.reasoning.isEmpty { Text(text("Razonamiento", "Reasoning")).font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(hidden)
                .accessibilityLabel(text("Elegir ", "Select ") + model.name).accessibilityIdentifier("provider.model." + model.id)
                .help(model.detail)
            Button { preferences.favorite(model.id) } label: {
                Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.yellow : .secondary)
            }.buttonStyle(.plain).help(text("Favorito", "Favorite"))
                .accessibilityLabel(text("Favorito ", "Favorite ") + model.name)
            Button { preferences.hide(model.id) } label: { Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                .buttonStyle(.plain).disabled(selected).help(text("Mostrar u ocultar", "Show or hide"))
                .accessibilityLabel(text("Visibilidad ", "Visibility ") + model.name)
            Menu {
                Button(text("Mover arriba", "Move up")) { preferences.move(model.id, offset: -1) }
                Button(text("Mover abajo", "Move down")) { preferences.move(model.id, offset: 1) }
                if preferences.modelPreferences.custom.contains(where: { $0.id == model.id }) {
                    Button(text("Eliminar modelo personalizado", "Remove custom model")) { preferences.removeCustomModel(model.id) }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(text("Opciones de ", "Options for ") + model.name)
        }.padding(10).opacity(hidden ? 0.55 : 1)
    }
}
