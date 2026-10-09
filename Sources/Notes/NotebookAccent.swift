import SwiftUI

/// Independent from the window gradient; an empty value follows the macOS accent.
enum NotebookAccent {
    static func color(_ stored: String) -> Color {
        guard !stored.isEmpty else { return Color(nsColor: .controlAccentColor) }
        return NotebookThemeStop.decode(stored).first?.color ?? Color(nsColor: .controlAccentColor)
    }
    static func encode(_ color: Color) -> String { NotebookThemeStop.encode([NotebookThemeStop(color: color)]) }
}

struct NotebookAccentPicker: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color de acento").font(.headline)
            CustomThemePicker(palette: .constant("custom"), singleColor: true)
        }
    }
}

struct NotebookToggleAccent: ViewModifier {
    var switchStyle = false
    @AppStorage("notes.accent") private var stored = ""
    @ViewBuilder
    func body(content: Content) -> some View {
        if switchStyle {
            content.toggleStyle(NotebookAccentSwitchStyle(color: NotebookAccent.color(stored)))
                .tint(NotebookAccent.color(stored)).accentColor(NotebookAccent.color(stored))
        } else {
            content.tint(NotebookAccent.color(stored)).accentColor(NotebookAccent.color(stored))
        }
    }
}

struct NotebookAccentSwitchStyle: ToggleStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let small = size == .mini || size == .small
        let height: CGFloat = small ? 16 : 22
        let width: CGFloat = small ? 28 : 38
        HStack(spacing: 8) {
            if size != .mini { configuration.label }
            Button { configuration.isOn.toggle() } label: {
                Capsule().fill(configuration.isOn ? color : Color.secondary.opacity(0.25))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            .frame(width: height - 4, height: height - 4).padding(2)
                    }.frame(width: width, height: height)
                    .contentShape(Capsule())
            }.buttonStyle(.plain)
        }.opacity(enabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: configuration.isOn)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
    }
}

struct NotebookStatusIndicator: View {
    @ObservedObject var media: MediaController
    @ObservedObject var assistant: NotebookAssistantController
    @ObservedObject var ai: AIController
    @AppStorage("notes.accent") private var stored = ""
    @AppStorage("notes.language") private var language = "es"
    private var active: Bool { media.isRecording || media.busy || assistant.runningNotebookID != nil || ai.running }
    private var color: Color { media.isRecording ? .red : NotebookAccent.color(stored) }
    private var title: String {
        if media.isRecording { return language == "en" ? "Recording" : "Grabando" }
        if assistant.runningNotebookID != nil { return NotebookAssistantText.display(assistant.progress, language: language) }
        if media.busy { return language == "en" ? "Processing recording…" : "Procesando grabación…" }
        return language == "en" ? "Working…" : "Trabajando…"
    }
    var body: some View {
        if active {
            HStack(spacing: 6) {
                if media.isRecording { Circle().fill(color).frame(width: 6, height: 6) }
                else { ProgressView().controlSize(.mini) }
                Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            }.padding(.horizontal, 11).padding(.vertical, 6)
                .frame(maxWidth: 300).fixedSize(horizontal: true, vertical: true)
                .modifier(NotebookInputSurface(radius: 100))
                .accessibilityElement(children: .ignore).accessibilityLabel(title)
                .accessibilityIdentifier("notebook.status")
                .allowsHitTesting(false)
        }
    }
}
