import SwiftUI
import LectureCore

enum NotebookColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown
    var id: String { rawValue }
    /// Explicit swatches: several system colours (pink vs red, mint vs teal,
    /// indigo vs blue) are too close in dark mode to match their names.
    var color: Color {
        let hex: UInt32 = switch self {
        case .red: 0xFF3B30; case .orange: 0xFF9500; case .yellow: 0xFFD60A; case .green: 0x34C759
        case .mint: 0x7FE5C8; case .teal: 0x138D90; case .blue: 0x0A84FF; case .indigo: 0x4B3FD1
        case .purple: 0x9B51E0; case .pink: 0xFF7EB9; case .brown: 0x8E6A45
        }
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    func title(_ language: String) -> String {
        let en = language == "en"
        switch self {
        case .red: return en ? "Red" : "Rojo"; case .orange: return en ? "Orange" : "Naranja"
        case .yellow: return en ? "Yellow" : "Amarillo"; case .green: return en ? "Green" : "Verde"
        case .mint: return en ? "Mint" : "Menta"; case .teal: return en ? "Teal" : "Verde azulado"
        case .blue: return en ? "Blue" : "Azul"; case .indigo: return en ? "Indigo" : "Índigo"
        case .purple: return en ? "Purple" : "Morado"; case .pink: return en ? "Pink" : "Rosa"
        case .brown: return en ? "Brown" : "Marrón"
        }
    }
    static func color(for notebook: Notebook) -> Color? { notebook.color.flatMap(NotebookColor.init(rawValue:))?.color }
}

/// Shared submenu for the sidebar context menu and the workspace actions panel.
struct NotebookColorMenu: View {
    @ObservedObject var model: Workbench
    let notebook: Notebook
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        Menu {
            Picker(language == "en" ? "Color" : "Color", selection: Binding(
                get: { notebook.color ?? "" },
                set: { try? model.setNotebookColor(notebook.id, color: $0.isEmpty ? nil : $0) })) {
                Text(language == "en" ? "Default" : "Predeterminado").tag("")
                ForEach(NotebookColor.allCases) { option in
                    Label { Text(option.title(language)) } icon: {
                        Image(nsImage: Self.swatch(NSColor(option.color)))
                    }.tag(option.rawValue)
                }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Label(language == "en" ? "Notebook color" : "Color del cuaderno", systemImage: "paintpalette")
        }.accessibilityIdentifier("notebook.color." + notebook.id)
    }
    // Menus render SF Symbols monochrome, so swatches are drawn as images.
    static func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        image.isTemplate = false
        return image
    }
}
