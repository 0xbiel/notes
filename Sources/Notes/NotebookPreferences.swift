import SwiftUI

/// Native counterpart to Zen's appearance-aware accent mixes and window material.
/// Preferences remain local and update the existing editor without replacing it.
enum NotebookPalette: String, CaseIterable, Identifiable {
    case graphite, blue, violet, sage, sand
    var id: Self { self }
    var title: String {
        switch self {
        case .graphite: "Grafito"
        case .blue: "Azul"
        case .violet: "Violeta"
        case .sage: "Salvia"
        case .sand: "Arena"
        }
    }
    var color: Color {
        switch self {
        case .graphite: Color.gray
        case .blue: Color(red: 0.25, green: 0.52, blue: 0.85)
        case .violet: Color(red: 0.58, green: 0.40, blue: 0.78)
        case .sage: Color(red: 0.36, green: 0.62, blue: 0.49)
        case .sand: Color(red: 0.76, green: 0.59, blue: 0.36)
        }
    }
}

struct NotebookThemeBackground: View {
    var blendsBehindWindow = false
    @AppStorage("notes.palette") private var palette = NotebookPalette.graphite.rawValue
    @AppStorage("notes.themeIntensity") private var intensity = 0.18
    @AppStorage("notes.sidebarTransparency") private var transparency = 1.0
    @AppStorage("notes.customThemeStops") private var storedStops = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private var neutralColor: Color { colorScheme == .dark ? .black : .white }
    private var color: Color { (NotebookPalette(rawValue: palette) ?? .graphite).color }
    var body: some View {
        ZStack {
            if palette == "custom" && NotebookThemeStop.decode(storedStops).isEmpty {
                if reduceTransparency {
                    neutralColor
                } else {
                    Group {
                        if blendsBehindWindow { SidebarVisualEffect() }
                        else { Rectangle().fill(.regularMaterial) }
                    }
                    neutralColor.opacity(1 - min(max(transparency, 0), 1))
                }
            } else {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else if blendsBehindWindow { SidebarVisualEffect() }
                else { Rectangle().fill(.regularMaterial) }
                // Keep labels fully opaque; vary only the backing surface.
                if !reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(1 - min(max(transparency, 0), 1))
                }
                LinearGradient(colors: palette == "custom"
                               ? NotebookThemeStop.decode(storedStops).map { $0.color.opacity(intensity) }
                               : [color.opacity(intensity), color.opacity(intensity * 0.25), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false)
    }
}

/// Uses the desktop behind the window as the sidebar's blurred backdrop.
private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SidebarSearchGlass: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ControlHoverBackground: ViewModifier {
    var cornerRadius: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovered && isEnabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

enum NotebookPreferencesSection: String, CaseIterable {
    case general, theme, providers, usage, transcription
    var title: LocalizedStringKey {
        switch self { case .general: "General"; case .theme: "Tema"; case .providers: "Proveedores IA"; case .usage: "Uso"; case .transcription: "Dictado" }
    }
    var symbol: String {
        switch self { case .general: "slider.horizontal.3"; case .theme: "paintpalette"; case .providers: "sparkles"; case .usage: "chart.bar"; case .transcription: "waveform" }
    }
}

struct NotebookPreferences: View {
    @ObservedObject var model: Workbench
    @Binding var section: NotebookPreferencesSection
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.confirmChatDeletion") private var confirmChatDeletion = true
    @AppStorage("notes.alwaysSteer") private var alwaysSteer = false
    @AppStorage("notes.documentWidth") private var documentWidth = "wide"
    @AppStorage("notes.latexDownloads") private var allowLaTeXDownloads = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title).font(.system(size: 13, weight: .medium))
                Spacer()
            }.padding(.horizontal, 18).frame(height: 58).background(WindowDragRegion())
            Divider().opacity(0.4)
            GeometryReader { geometry in
                let inset: CGFloat = geometry.size.width < 700 ? 24 : 40
                ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(section == .general ? "Preferencias" : section.title).font(.largeTitle.weight(.semibold))
                    if section == .theme {
                        NotebookThemePreferences().frame(maxWidth: 500)
                    } else if section == .transcription {
                        if let media = model.media { TranscriptionPreferences(media: media) }
                    } else if section == .usage {
                        if let ai = model.ai {
                            UsagePreferences(workspace: ai.outbox.workspace).id(ai.outbox.workspace.root.path)
                        } else {
                            Text("Abre un espacio local para ver el uso.").foregroundStyle(.secondary)
                        }
                    } else if section == .providers {
                        if let ai = model.ai {
                            ProviderPreferences(ai: ai, contentWidth: max(0, min(680, geometry.size.width - inset * 2)))
                                .id(ai.outbox.workspace.root.path)
                        } else {
                            Text("Abre un espacio local para configurar los proveedores.").foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(language == "en" ? "Text documents" : "Documentos de texto").font(.headline)
                            DocumentReadingWidthPicker(selection: $documentWidth)
                            Text(language == "en" ? "Standard centers an A4-like reading column. Wide uses the available space. Both shrink with the window." : "Estándar centra una columna de lectura similar a A4. Amplio aprovecha el espacio disponible. Ambos se adaptan al reducir la ventana.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("LaTeX").font(.headline)
                            Toggle(language == "en" ? "Allow missing TeX package downloads" : "Permitir descargar paquetes TeX faltantes", isOn: $allowLaTeXDownloads)
                                .modifier(NotebookToggleAccent(switchStyle: true))
                                .accessibilityIdentifier("preferences.latexDownloads")
                            Text(language == "en" ? "Compilation stays on your Mac. Tectonic can download missing packages; turn this off to use only cached packages." : "La compilación se realiza en tu Mac. Tectonic puede descargar paquetes faltantes; desactívalo para usar solo los paquetes en caché.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        if let ai = model.ai {
                            GeneralAIPreferences(ai: ai) { section = .providers }.id(ai.outbox.workspace.root.path)
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(language == "en" ? "Chats" : "Chats").font(.headline)
                            Toggle(language == "en" ? "Always steer instead of queueing" : "Dirigir siempre en lugar de añadir a la cola", isOn: $alwaysSteer)
                                .modifier(NotebookToggleAccent(switchStyle: true))
                                .accessibilityIdentifier("preferences.alwaysSteer")
                            Text(language == "en" ? "While the assistant is working, new messages queue by default. Turn this on to interrupt the current response and continue with your new instructions." : "Mientras el asistente trabaja, los mensajes nuevos se añaden a la cola. Actívalo para interrumpir la respuesta actual y continuar con tus nuevas instrucciones.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle(language == "en" ? "Confirm before deleting chats" : "Confirmar antes de eliminar chats", isOn: $confirmChatDeletion)
                                .modifier(NotebookToggleAccent(switchStyle: true))
                                .accessibilityIdentifier("preferences.confirmChatDeletion")
                            Text(language == "en" ? "Turn off to delete chats immediately. Documents and checkpoints are kept." : "Desactívalo para eliminar chats directamente. Se conservan los documentos y el historial.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Idioma").font(.headline)
                            AIOptionSelector(title: "Idioma / Language", symbol: "globe", options: [
                                .init(id: "es", title: "Español"), .init(id: "en", title: "English")
                            ], selection: $language)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text(language == "en" ? "Introduction" : "Introducción").font(.headline)
                            Button { model.showPreferences = false; model.showOnboarding = true } label: {
                                Label(language == "en" ? "Show the introduction" : "Ver la introducción", systemImage: "play.circle")
                                    .font(.callout).padding(.horizontal, 10).frame(height: 34).modifier(NotebookInputSurface(radius: 7))
                            }.buttonStyle(.plain).accessibilityIdentifier("preferences.showOnboarding")
                        }
                    }
                }.frame(width: max(0, min(680, geometry.size.width - inset * 2)), alignment: .leading)
                    .padding(inset).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

struct NotebookPreferencesSidebar: View {
    @Binding var section: NotebookPreferencesSection
    var compact = false
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferencias").font(.title2.weight(.semibold)).padding(.horizontal, 16)
            VStack(spacing: 6) {
                ForEach(NotebookPreferencesSection.allCases, id: \.self) { item in
                    sectionButton(item.title, symbol: item.symbol, selected: section == item) { section = item }
                }
            }.padding(.horizontal, 12)
            Spacer()
            Button(action: onBack) {
                Label("Volver a notas", systemImage: "arrow.left")
                    .font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(ControlHoverBackground(cornerRadius: compact ? CompactLayout.rowRadius : 8)).keyboardShortcut(.cancelAction).padding(.horizontal, 12)
        }.padding(.top, 10).padding(.bottom, 12)
    }

    private func sectionButton(_ title: LocalizedStringKey, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: compact ? CompactLayout.rowRadius : 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(ControlHoverBackground(cornerRadius: compact ? CompactLayout.rowRadius : 8)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NotebookThemePreferences: View {
    @AppStorage("notes.palette") private var palette = NotebookPalette.graphite.rawValue
    @AppStorage("notes.themeIntensity") private var intensity = 0.18
    @AppStorage("notes.sidebarTransparency") private var transparency = 1.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NotebookAccentPicker()
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Color del marco").font(.headline)
                CustomThemePicker(palette: $palette)
                HStack {
                    Text("Intensidad").font(.callout)
                    Slider(value: $intensity, in: 0...0.5)
                        .controlSize(.regular)
                        .accessibilityIdentifier("theme.intensity")
                        .accessibilityLabel("Intensidad del color")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Transparencia de la barra lateral").font(.headline)
                    Spacer()
                    Text(transparency, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $transparency, in: 0...1, step: 0.01)
                    .controlSize(.regular)
                    .accessibilityIdentifier("theme.transparency")
                    .accessibilityLabel("Transparencia de la barra lateral")
                    .accessibilityValue(Text(transparency, format: .percent.precision(.fractionLength(0))))
                    .disabled(reduceTransparency)
                HStack {
                    Text("Opaca")
                    Spacer()
                    Text("Translúcida")
                }.font(.caption).foregroundStyle(.secondary)
                if reduceTransparency {
                    Text("Desactiva Reducir transparencia en los ajustes de accesibilidad de macOS para usar este control.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.08))
                    .frame(width: 60)
                RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor))
                    .overlay(Text("Vista previa").font(.caption).foregroundStyle(.secondary))
            }.padding(8).frame(height: 70).background(NotebookThemeBackground().clipShape(RoundedRectangle(cornerRadius: 14)))
        }
    }
}
