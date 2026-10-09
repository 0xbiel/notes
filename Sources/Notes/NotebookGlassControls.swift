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
