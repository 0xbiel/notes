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
