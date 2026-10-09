import SwiftUI

struct NotebookInputSurface: ViewModifier {
    var radius: CGFloat = 10
    var floating = false
    var opaque = false
    var borderOpacity: Double = 0.35
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius)
            if opaque || reduceTransparency { shape.fill(Color(nsColor: .controlBackgroundColor)) }
            else if floating { shape.fill(.ultraThinMaterial) }
            else { shape.fill(Color.primary.opacity(0.045)) }
        }
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.separator.opacity(borderOpacity), lineWidth: 1))
        .shadow(color: .black.opacity(floating ? 0.08 : 0), radius: 12, y: 4)
    }
}
