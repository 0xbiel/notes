import SwiftUI
import LectureCore

struct AIPermissionsSelector: View {
    @Binding var selection: AIEditAutonomy
    @State private var presented = false
    @State private var hovered: AIEditAutonomy?
    @AppStorage("notes.language") private var language = "es"

    private let options: [AIEditAutonomy] = [.review, .edits, .automatic, .fullAccess]
    private var selected: AIEditAutonomy { selection == .additions ? .automatic : selection }
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private func title(_ option: AIEditAutonomy) -> String {
        switch option {
        case .review: text("Supervisado", "Supervised")
        case .edits: text("Aceptar ediciones", "Auto-accept edits")
        case .automatic, .additions: text("Auto", "Auto")
        case .fullAccess: text("Acceso completo", "Full access")
        }
    }
    private func symbol(_ option: AIEditAutonomy) -> String {
        switch option {
        case .review: "lock"
        case .edits: "pencil"
        case .automatic, .additions: "sparkles"
        case .fullAccess: "lock.slash"
        }
    }
    private func detail(_ option: AIEditAutonomy) -> String {
        switch option {
        case .review:
            text("Preguntar antes de ejecutar comandos o cambiar archivos.", "Ask before commands and file changes.")
        case .edits:
            text("Aprobar ediciones; preguntar antes de ejecutar comandos.", "Auto-approve edits; ask before commands.")
        case .automatic, .additions:
            text("Aprobar ediciones e inspecciones rutinarias; preguntar por otros comandos.", "Approve edits and routine inspections; ask before other commands.")
        case .fullAccess:
            text("Permitir comandos y cambios de archivos sin confirmación.", "Allow commands and file changes without prompts.")
        }
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol(selected)).foregroundStyle(.secondary)
                Text(title(selected)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.callout).padding(.horizontal, 9).frame(height: 34)
            .modifier(NotebookSolidControlSurface())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text("Permisos", "Permissions"))
        .accessibilityValue(title(selected))
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        presented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Image(systemName: symbol(option)).foregroundStyle(.secondary).frame(width: 18)
                                Text(title(option)).font(.system(size: 13))
                                Spacer()
                                if selected == option { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                            }
                            Text(detail(option)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .modifier(SelectorRowBackground(highlighted: selected == option || hovered == option))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? option : nil }
                    .accessibilityAddTraits(selected == option ? .isSelected : [])
                }
                Divider().padding(.vertical, 4)
                Text(text("Los comandos se ejecutan en tu Mac con el acceso de Palladium. Sus cambios no se deshacen con los puntos de control de notas.", "Commands run on your Mac with Palladium’s access. Command changes are not undone by note checkpoints."))
                    .font(.caption).foregroundStyle(.secondary).padding(9)
            }
            .padding(5).frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand { presented = false }
        }
    }
}
