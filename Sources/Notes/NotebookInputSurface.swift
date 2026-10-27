import SwiftUI

struct NotebookInputSurface: ViewModifier {
    var radius: CGFloat = 10
    var floating = false
    var opaque = false
    var borderOpacity: Double = 0.35
    var fillOpacity: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            if opaque || reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else if !floating {
                shape.fill(Color.primary.opacity(0.045))
            } else if #available(macOS 26.0, *) {
                shape.fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: radius))
                    .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity)))
            } else {
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity)))
            }
        }
        .overlay {
            if !floating { shape.strokeBorder(.separator.opacity(borderOpacity), lineWidth: 1) }
            else if borderOpacity > 0 { shape.strokeBorder(
            LinearGradient(colors: [.white.opacity(reduceTransparency ? 0 : 0.22),
                                    .primary.opacity(borderOpacity * 0.16),
                                    .white.opacity(reduceTransparency ? 0 : 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1) }
        }
        .shadow(color: .black.opacity(floating ? 0.14 : 0), radius: 18, y: 6)
    }
}

/// Shared geometry for selected and hovered rows inside selector popovers.
struct SelectorRowBackground: ViewModifier {
    let highlighted: Bool
    func body(content: Content) -> some View {
        content.background(highlighted ? Color.primary.opacity(0.1) : .clear,
                           in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
