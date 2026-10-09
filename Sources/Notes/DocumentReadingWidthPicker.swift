import SwiftUI

struct DocumentReadingWidthPicker: View {
    @Binding var selection: String
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    var body: some View {
        HStack(spacing: 12) {
            option(.standard, title: language == "en" ? "Standard" : "Estándar")
            option(.wide, title: language == "en" ? "Wide" : "Amplio")
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(language == "en" ? "Reading width" : "Ancho de lectura")
            .accessibilityIdentifier("preferences.documentWidth")
    }
    private func option(_ width: DocumentReadingWidth, title: String) -> some View {
        let selected = selection == width.rawValue
        return Button { selection = width.rawValue } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.55)))
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).frame(width: width == .standard ? 36 : 56, height: 4)
                        ForEach(0..<6) { row in
                            RoundedRectangle(cornerRadius: 1)
                                .frame(width: row == 5 ? (width == .standard ? 42 : 80) : nil, height: 2)
                        }
                    }.foregroundStyle(selected ? NotebookAccent.color(accent) : .secondary)
                        .frame(width: width == .standard ? 64 : 116)
                }.frame(width: 144, height: 100)
                HStack(spacing: 5) {
                    Text(title).font(.callout.weight(selected ? .semibold : .regular))
                    if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(NotebookAccent.color(accent)) }
                }
            }.padding(12).frame(width: 168)
                .modifier(NotebookInputSurface(radius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? NotebookAccent.color(accent).opacity(0.8) : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("preferences.documentWidth." + width.rawValue)
    }
}
