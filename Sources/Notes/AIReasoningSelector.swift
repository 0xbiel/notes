import SwiftUI

/// Auto leaves the provider effort unset; manual stops use the model's supported levels.
struct AIReasoningSelector: View {
    let levels: [String]
    var modelName: String? = nil
    var fastMode: Binding<Bool>? = nil
    @Binding var selection: String
    @State private var presented = false
    @State private var dragPosition: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private var color: Color { NotebookAccent.color(accent) }
    private var fast: Bool { fastMode?.wrappedValue == true }
    private var automatic: Bool { selection == "auto" }
    private var stops: [String] { ["auto"] + levels.filter { $0 != "auto" } }
    private var selectedIndex: Int { stops.firstIndex(of: selection) ?? 0 }
    private var shownIndex: Int { min(stops.count - 1, max(0, Int((dragPosition ?? CGFloat(selectedIndex)).rounded()))) }
    private var title: String { language == "en" ? "Reasoning" : "Razonamiento" }
    private func label(_ level: String) -> String {
        if level == "auto" { return "Auto" }
        if language == "en" { return level == "xhigh" ? "Extra High" : level.capitalized }
        return ["none": "Ninguno", "minimal": "Mínimo", "low": "Bajo", "medium": "Medio", "high": "Alto", "xhigh": "Extra alto", "max": "Máximo", "ultra": "Ultra"][level] ?? level.capitalized
    }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: fast ? "bolt.fill" : automatic ? "sparkles" : "brain").foregroundStyle(color)
                Text(label(selection))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.callout).padding(.horizontal, 9).frame(height: 34)
                .modifier(NotebookInputSurface(radius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(label(selection) + (fast ? " · Fast" : ""))
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    ZStack {
                        HStack(spacing: 4) {
                            Text(modelName ?? title).foregroundStyle(.primary)
                            Text(label(stops[shownIndex])).foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }.font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, fastMode == nil ? 0 : 26)
                        if let fastMode {
                            HStack {
                                Button { fastMode.wrappedValue.toggle() } label: {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(fastMode.wrappedValue ? color : Color.secondary)
                                        .frame(width: 24, height: 24).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .help(language == "en" ? "Fast mode" : "Modo rápido")
                                    .accessibilityLabel(language == "en" ? "Fast mode" : "Modo rápido")
                                    .accessibilityValue(fastMode.wrappedValue ? "On" : "Off")
                                    .accessibilityAddTraits(fastMode.wrappedValue ? .isSelected : [])
                                    .accessibilityIdentifier("reasoning.fast")
                                Spacer()
                            }
                        }
                    }.frame(height: 24)
                    track
                    GeometryReader { geometry in
                        let step = (geometry.size.width - 28) / CGFloat(max(1, stops.count - 1))
                        ZStack(alignment: .leading) {
                            Text("Auto").frame(width: 28)
                                .help(language == "en" ? "Use the model’s default reasoning level" : "Usar el nivel predeterminado del modelo")
                            if let low = levels.first(where: { $0 == "low" }) ?? levels.first, let index = stops.firstIndex(of: low) {
                                Text(label(low)).fixedSize().frame(width: 28).offset(x: CGFloat(index) * step)
                            }
                            HStack { Spacer(); Text(levels.last.map(label) ?? "") }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(height: 12)
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(width: 280)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onExitCommand { presented = false }
            }
    }

    private var track: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 28)
            let step = travel / CGFloat(max(1, stops.count - 1))
            let position = dragPosition ?? CGFloat(selectedIndex)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 24)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                Capsule().fill(color).frame(width: 28 + position * step, height: 24)
                    .overlay {
                        if fast && !reduceMotion {
                            FastReasoningParticles().clipShape(Capsule())
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                ForEach(Array(stops.enumerated()), id: \.element) { index, level in
                    Circle().fill(Color.white.opacity(CGFloat(index) <= position ? 0.55 : 0.3))
                        .frame(width: 4, height: 4).frame(width: 28, height: 28)
                        .offset(x: CGFloat(index) * step)
                        .help(label(level)).accessibilityHidden(true)
                }
                Circle().fill(.white).frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: 1 + position * step)
            }.frame(height: 28).contentShape(Rectangle())
                .animation(dragPosition == nil && !reduceMotion ? .spring(response: 0.25, dampingFraction: 0.8) : nil, value: position)
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragPosition = min(CGFloat(stops.count - 1), max(0, (value.location.x - 14) / step))
                    }
                    .onEnded { _ in
                        selection = stops[shownIndex]
                        dragPosition = nil
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title).accessibilityValue(label(stops[shownIndex]))
                .accessibilityIdentifier("reasoning.slider")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: selection = stops[min(stops.count - 1, selectedIndex + 1)]
                    case .decrement: selection = stops[max(0, selectedIndex - 1)]
                    @unknown default: break
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    if direction == .right { selection = stops[min(stops.count - 1, selectedIndex + 1)] }
                    if direction == .left { selection = stops[max(0, selectedIndex - 1)] }
                }
        }.frame(height: 28)
    }
}

/// Small drifting sparks, rendered only while the Fast track is visible.
private struct FastReasoningParticles: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<12 {
                    let seed = Double(index)
                    let duration = 0.75 + (seed.truncatingRemainder(dividingBy: 4)) * 0.1
                    let phase = (time / duration + seed * 0.618).truncatingRemainder(dividingBy: 1)
                    let x = (1 - phase) * (size.width + 8) - 4
                    let y = 3 + (seed * 7.13).truncatingRemainder(dividingBy: max(1, size.height - 6))
                        + sin(time * 1.8 + seed) * 1.5
                    let radius = 0.6 + (seed * 0.37).truncatingRemainder(dividingBy: 0.7)
                    let fade = sin(phase * .pi) * 0.7
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                                 with: .color(.white.opacity(fade)))
                }
            }
        }
    }
}
