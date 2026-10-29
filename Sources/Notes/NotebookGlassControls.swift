import SwiftUI

struct NotebookGlassSelector: View {
    @Binding var selection: String
    let options: [AIOption]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var animation
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = option.id } } label: {
                    Text(option.title).font(.system(size: 13, weight: selection == option.id ? .semibold : .regular))
                        .foregroundStyle(selection == option.id ? .primary : .secondary)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background {
                            if selection == option.id {
                                if #available(macOS 26.0, *), !reduceTransparency {
                                    Capsule().fill(.clear).glassEffect(.regular.interactive(), in: .capsule)
                                        .matchedGeometryEffect(id: "selection", in: animation)
                                } else {
                                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                        .overlay(Capsule().stroke(.separator.opacity(0.5)))
                                }
                            }
                        }.contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == option.id ? .isSelected : [])
            }
        }.padding(4).background(.primary.opacity(0.045), in: Capsule())
    }
}

struct NotebookGlassCloseSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else { content.modifier(NotebookInputSurface(radius: 100)) }
    }
}

/// Solid inset controls keep the composer's outer glass surface visually distinct.
struct NotebookSolidButtonStyle: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .modifier(NotebookSolidControlSurface(tint: tint))
            .overlay(Capsule().fill(.black.opacity(configuration.isPressed ? 0.08 : 0)))
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct NotebookSolidControlSurface: ViewModifier {
    var tint: Color? = nil
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background(tint ?? Color(white: colorScheme == .dark ? 0.26 : 0.88), in: Capsule())
    }
}

/// The chat disclosure sits outside the composer so its glass samples the document.
struct NotebookChatPillStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                configuration.label.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                configuration.label.modifier(NotebookInputSurface(radius: 100, floating: true))
            }
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The draggable glass control used in the title bar and introduction.
struct NotebookSlidingSelector: View {
    @Binding var selection: String
    let options: [AIOption]
    var segment: CGFloat = 76
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat?
    @State private var pressed = false
    private var selectedIndex: Int { options.firstIndex { $0.id == selection } ?? 0 }
    private var restingOffset: CGFloat { CGFloat(selectedIndex) * segment }
    private var thumbOffset: CGFloat { dragOffset ?? restingOffset }
    private var hoveredIndex: Int { index(at: thumbOffset + segment / 2) }

    private func index(at position: CGFloat) -> Int {
        min(max(Int(floor(position / segment)), 0), max(options.count - 1, 0))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            thumb
                .frame(width: segment, height: 26)
                .scaleEffect(pressed ? 1.08 : 1)
                .offset(x: thumbOffset)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    Text(option.title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hoveredIndex == index ? .primary : .secondary)
                        .frame(width: segment, height: 26)
                        .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                }
            }.allowsHitTesting(false)
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            if !pressed { animate { pressed = true } }
            // Small moves are treated as a click; the thumb only tracks once the pointer travels.
            guard abs(drag.translation.width) > 3 else { return }
            dragOffset = min(max(drag.location.x - 2 - segment / 2, 0), CGFloat(max(options.count - 1, 0)) * segment)
        }.onEnded { drag in
            let target = abs(drag.translation.width) > 3 ? hoveredIndex : index(at: drag.location.x - 2)
            animate {
                if options.indices.contains(target) { selection = options[target].id }
                dragOffset = nil
                pressed = false
            }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityValue(options.first { $0.id == selection }?.title ?? "")
        .accessibilityAdjustableAction { direction in
            let next = selectedIndex + (direction == .increment ? 1 : -1)
            guard options.indices.contains(next) else { return }
            animate { selection = options[next].id }
        }
    }

    @ViewBuilder private var thumb: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Capsule().fill(.clear).glassEffect(pressed ? .clear.interactive() : .regular.interactive(), in: .capsule)
                .shadow(color: .black.opacity(pressed ? 0.12 : 0.06), radius: pressed ? 6 : 2, y: 1)
        } else {
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
        }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), change)
    }
}
