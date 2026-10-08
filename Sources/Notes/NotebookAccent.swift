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

struct NotebookStatusIndicator: View {
    @ObservedObject var media: MediaController
    @ObservedObject var assistant: NotebookAssistantController
    @ObservedObject var ai: AIController
    @AppStorage("notes.accent") private var stored = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { media.isRecording || assistant.runningNotebookID != nil || ai.running }
    private var color: Color { media.isRecording ? .red : NotebookAccent.color(stored) }
    var body: some View {
        if active {
            Group {
                if reduceMotion { Capsule().fill(color).frame(height: 4) }
                else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        Capsule().fill(color.opacity(0.3))
                            .overlay {
                                LinearGradient(colors: [.clear, color, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 48).offset(x: (phase * 2 - 1) * 80)
                            }
                            .clipShape(Capsule())
                    }
                }
            }.frame(width: 112, height: 4)
                .accessibilityElement(children: .ignore).accessibilityLabel(media.isRecording ? "Grabando" : "Trabajando")
                .accessibilityIdentifier("notebook.status")
                .allowsHitTesting(false)
        }
    }
}
