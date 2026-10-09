import SwiftUI
import LectureCore

struct AIModelSelector: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    let manageProviders: () -> Void
    @State private var isPresented = false
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 7) {
                ProviderLogo(provider: preferences.draft.selectedProvider, size: 17)
                Text(preferences.selectedModel?.name ?? preferences.draft.selected.model).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 10).frame(height: 34)
                .modifier(NotebookInputSurface(radius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("general.ai.model")
            .accessibilityLabel(language == "en" ? "Choose provider and model" : "Elegir proveedor y modelo")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                AIModelSelectorPopover(preferences: preferences, onSelect: { isPresented = false }, manageProviders: {
                    isPresented = false; manageProviders()
                })
            }
    }
}

struct AIModelSelectorPopover: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    let onSelect: () -> Void
    let manageProviders: () -> Void
    @State private var provider: NotesAIProvider?
    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""

    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private func providerName(_ value: NotesAIProvider) -> String {
        switch value { case .codexCLI: "Codex"; case .openCode: "OpenCode · OpenRouter"; case .antigravity: "Antigravity" }
    }
    private var rows: [SelectorEntry] {
        (provider.map { [$0] } ?? [.codexCLI, .openCode, .antigravity]).flatMap { source in
            guard preferences.draft.configuration(for: source).accountSendingAllowed else { return [SelectorEntry]() }
            let options = preferences.draft.modelPreferences?[source.rawValue] ?? .init()
            return preferences.models(for: source).filter { model in
                !options.hidden.contains(model.id) && (provider != nil || !query.isEmpty || options.favorites.contains(model.id)) &&
                (query.isEmpty || (model.name + " " + model.id + " " + providerName(source)).localizedCaseInsensitiveContains(query))
            }.map { SelectorEntry(provider: source, model: $0, favorite: options.favorites.contains($0.id)) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 6) {
                    railButton(nil)
                    Divider().padding(.horizontal, 5)
                    ForEach([NotesAIProvider.codexCLI, .openCode, .antigravity].filter { preferences.draft.configuration(for: $0).accountSendingAllowed }) { railButton($0) }
                    Spacer()
                }.padding(6).frame(width: 44)
                Divider()
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(text("Buscar modelos…", "Search models…"), text: $query)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .accessibilityIdentifier("general.ai.search")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 11).padding(.horizontal, 10)
                    Rectangle().fill(searchFocused ? NotebookAccent.color(accent) : Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 9)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in modelRow(entry, index: index) }
                            if rows.isEmpty {
                                Text(provider == nil && query.isEmpty ? text("Marca modelos con la estrella para verlos aquí.", "Star models to see them here.") : text("No hay modelos. Actualiza el catálogo en Proveedores.", "No models found. Refresh the catalog in Providers."))
                                    .font(.callout).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity)
                            }
                        }.padding(8)
                    }.frame(height: 246)
                }
            }
            Divider()
            HStack(spacing: 7) {
                ProviderLogo(provider: preferences.draft.selectedProvider, size: 13)
                Text(preferences.draft.selectedProvider == .openCode ? "OpenRouter" : text("Cuenta del proveedor", "Provider account"))
                    .lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button(action: manageProviders) {
                    HStack(spacing: 4) { Text(text("Gestionar", "Manage")); Image(systemName: "arrow.up.right") }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.caption).padding(12)
        }.frame(width: 370)
            .background(Color(nsColor: .windowBackgroundColor))
            .background(NotebookAccentCaret()).tint(NotebookAccent.color(accent))
            .onAppear {
                let hasFavorites = preferences.draft.modelPreferences?.values.contains { !$0.favorites.isEmpty } ?? false
                provider = hasFavorites ? nil : preferences.draft.selectedProvider
                searchFocused = true
            }
            .task { await preferences.loadCatalogs() }
    }

    private func railButton(_ value: NotesAIProvider?) -> some View {
        Button { provider = value; query = "" } label: {
            Group {
                if let value { ProviderLogo(provider: value, size: 20) }
                else { Image(systemName: "star.fill").font(.system(size: 19)) }
            }.frame(width: 32, height: 32)
                .background(provider == value ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) {
                    if provider == value { Capsule().fill(NotebookAccent.color(accent)).frame(width: 2, height: 18).offset(x: -6) }
                }
        }.buttonStyle(.plain)
            .help(value.map(providerName) ?? text("Favoritos", "Favorites"))
            .accessibilityLabel(value.map(providerName) ?? text("Favoritos", "Favorites"))
            .accessibilityIdentifier("general.ai.filter." + (value?.rawValue ?? "favorites"))
            .accessibilityAddTraits(provider == value ? .isSelected : [])
    }

    private func modelRow(_ entry: SelectorEntry, index: Int) -> some View {
        let selected = preferences.draft.selectedProvider == entry.provider && preferences.draft.selected.model == entry.model.id
        return HStack(spacing: 8) {
            Button {
                preferences.draft.selectedProvider = entry.provider
                preferences.selectModel(entry.model.id)
                onSelect()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.model.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            ProviderLogo(provider: entry.provider, size: 12)
                            Text(providerName(entry.provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("general.ai.choose." + entry.id)
            Button { preferences.favorite(entry.model.id, provider: entry.provider) } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star").font(.system(size: 11))
                    .foregroundStyle(entry.favorite ? Color.orange : Color.secondary.opacity(0.6))
                    .frame(width: 20, height: 28)
            }.buttonStyle(.plain).accessibilityLabel(text("Favorito ", "Favorite ") + entry.model.name)
        }.padding(.horizontal, 8).padding(.vertical, 8)
            .background(selected || hovered == entry.id ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 ? entry.id : nil }
    }
}

private struct SelectorEntry: Identifiable {
    let provider: NotesAIProvider
    let model: AIProviderModel
    let favorite: Bool
    var id: String { provider.rawValue + "." + model.id }
}
