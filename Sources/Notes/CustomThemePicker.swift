import SwiftUI
import AppKit

// Native interaction inspired by Zen's theme-picker.inc and ZenGradientGenerator.mjs:
// https://github.com/zen-browser/desktop/tree/dev/src/zen/spaces
// Independent SwiftUI implementation; no JavaScript or CSS is embedded.
struct NotebookThemeStop: Codable, Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
    static let initial = Self(hue: 0.60, saturation: 0.55, brightness: 0.85)

    static func decode(_ value: String) -> [Self] {
        guard let data = value.data(using: .utf8),
              let stops = try? JSONDecoder().decode([Self].self, from: data),
              (1...3).contains(stops.count),
              stops.allSatisfy({ [$0.hue, $0.saturation, $0.brightness].allSatisfy { $0.isFinite && (0...1).contains($0) } })
        else { return [.initial] }
        return stops
    }

    static func encode(_ stops: [Self]) -> String {
        guard let data = try? JSONEncoder().encode(stops) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness
    }

    init(color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(hue: rgb.hueComponent, saturation: rgb.saturationComponent, brightness: rgb.brightnessComponent)
    }
}

struct CustomThemePicker: View {
    @Binding var palette: String
    @AppStorage("notes.customThemeStops") private var storedStops = ""
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.appearance") private var appearance = "system"
    @State private var selected = 0
    @State private var dragging = false
    private var stops: [NotebookThemeStop] { NotebookThemeStop.decode(storedStops) }
    private var index: Int { min(selected, stops.count - 1) }
    private func label(_ es: String, _ en: String) -> String { language == "en" ? en : es }

    private func update(_ edit: (inout NotebookThemeStop) -> Void) {
        var values = stops
        edit(&values[index])
        storedStops = NotebookThemeStop.encode(values)
        palette = "custom"
    }

    private func addColor() {
        var values = stops
        guard values.count < 3 else { return }
        values.append(.init(hue: (values[index].hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.85))
        storedStops = NotebookThemeStop.encode(values)
        selected = values.count - 1
        palette = "custom"
    }

    private func removeColor() {
        var values = stops
        guard values.count > 1 else { return }
        values.remove(at: index)
        selected = max(0, index - 1)
        storedStops = NotebookThemeStop.encode(values)
        palette = "custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorField
                .overlay(alignment: .top) {
                    HStack(spacing: 5) {
                        schemeButton("system", "circle.lefthalf.filled", label("Sistema", "System"))
                        schemeButton("light", "sun.max", label("Claro", "Light"))
                        schemeButton("dark", "moon", label("Oscuro", "Dark"))
                    }.padding(8)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 5) {
                        Button(action: addColor) { Image(systemName: "plus").frame(width: 30, height: 30) }
                            .disabled(stops.count == 3).accessibilityLabel(label("Añadir color", "Add color"))
                        Button(action: removeColor) { Image(systemName: "minus").frame(width: 30, height: 30) }
                            .disabled(stops.count == 1).accessibilityLabel(label("Quitar color", "Remove color"))
                    }.buttonStyle(.borderless).padding(8)
                }
            HStack(spacing: 12) {
                ForEach(NotebookPalette.allCases) { option in
                    Button { palette = option.rawValue } label: {
                        Circle().fill(option.color.gradient).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(palette == option.rawValue ? Color.primary : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(LocalizedStringKey(option.title))
                        .accessibilityLabel(LocalizedStringKey(option.title))
                        .accessibilityAddTraits(palette == option.rawValue ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { palette = "custom" } label: {
                    Circle().fill(LinearGradient(colors: stops.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(palette == "custom" ? Color.primary : .clear, lineWidth: 2))
                }.buttonStyle(.plain).help(label("Personalizado", "Custom"))
                    .accessibilityLabel(label("Personalizado", "Custom"))
                    .accessibilityAddTraits(palette == "custom" ? .isSelected : [])
            }.padding(.horizontal, 8)
            HStack {
                Text(label("Luminosidad", "Brightness")).font(.callout)
                Slider(value: Binding(get: { stops[index].brightness }, set: { value in update { $0.brightness = value } }), in: 0...1)
                    .accessibilityLabel(label("Luminosidad", "Brightness"))
                ColorPicker(label("Color exacto", "Exact color"), selection: Binding(
                    get: { stops[index].color }, set: { color in update { $0 = .init(color: color) } }
                ), supportsOpacity: false).labelsHidden()
                    .help(label("Color exacto", "Exact color"))
            }
        }
    }

    private func schemeButton(_ value: String, _ symbol: String, _ title: String) -> some View {
        Button { appearance = value } label: {
            Image(systemName: symbol).frame(width: 30, height: 30)
                .background(appearance == value ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
            .accessibilityAddTraits(appearance == value ? .isSelected : [])
    }

    private func position(_ stop: NotebookThemeStop, in size: CGSize) -> CGPoint {
        let radius = min(size.width, size.height) / 2 - 48
        let angle = stop.hue * 2 * Double.pi
        return CGPoint(x: size.width / 2 + cos(angle) * stop.saturation * radius,
                       y: size.height / 2 + sin(angle) * stop.saturation * radius)
    }

    private var colorField: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.035)
                Canvas { context, size in
                    for x in stride(from: 3.0, to: size.width, by: 6) {
                        for y in stride(from: 3.0, to: size.height, by: 6) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.primary.opacity(0.13)))
                        }
                    }
                }.allowsHitTesting(false)
                ForEach(stops.indices, id: \.self) { offset in
                    Circle().fill(stops[offset].color)
                        .frame(width: offset == index ? 38 : 24, height: offset == index ? 38 : 24)
                        .overlay(Circle().strokeBorder(.white, lineWidth: offset == index ? 5 : 3))
                        .shadow(color: .black.opacity(0.18), radius: 2)
                        .position(position(stops[offset], in: geometry.size))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if !dragging {
                    if let closest = stops.indices.min(by: {
                        let a = position(stops[$0], in: geometry.size)
                        let b = position(stops[$1], in: geometry.size)
                        return hypot(a.x - value.startLocation.x, a.y - value.startLocation.y) < hypot(b.x - value.startLocation.x, b.y - value.startLocation.y)
                    }) { selected = closest }
                    dragging = true
                }
                let dx = value.location.x - geometry.size.width / 2
                let dy = value.location.y - geometry.size.height / 2
                let radius = min(geometry.size.width, geometry.size.height) / 2 - 48
                update {
                    $0.hue = (atan2(dy, dx) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                    $0.saturation = min(1, max(0, hypot(dx, dy) / radius))
                }
            }.onEnded { _ in dragging = false })
            .accessibilityElement(children: .ignore).accessibilityLabel(label("Campo de color", "Color field"))
            .accessibilityHint(label("Usa Color exacto para seleccionar con el teclado.", "Use Exact color to select with the keyboard."))
            .accessibilityAction(named: Text(label("Siguiente color", "Next color"))) { selected = (index + 1) % stops.count }
            .accessibilityAdjustableAction { direction in
                update { $0.hue = ($0.hue + (direction == .increment ? 0.025 : 0.975)).truncatingRemainder(dividingBy: 1) }
            }
        }.frame(height: 260)
    }
}
