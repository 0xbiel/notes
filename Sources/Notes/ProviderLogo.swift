import SwiftUI
import LectureCore

struct ProviderLogo: View {
    let provider: NotesAIProvider
    var size: CGFloat = 26
    /// Optional `#RRGGBB` instance color, shown as a small badge.
    var accent: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var resource: String? {
        switch provider { case .codexCLI: "codex"; case .claudeCode: "claude"; case .antigravity: "antigravity"; case .openCode: nil }
    }

    var body: some View {
        Group {
            if provider == .openCode {
                Canvas { context, bounds in
                    let scale = min(bounds.width / 32, bounds.height / 40)
                    context.translateBy(x: (bounds.width - 32 * scale) / 2, y: (bounds.height - 40 * scale) / 2)
                    context.scaleBy(x: scale, y: scale)
                    var ring = Path(CGRect(x: 0, y: 0, width: 32, height: 40))
                    ring.addRect(CGRect(x: 8, y: 8, width: 16, height: 24))
                    context.fill(ring, with: .color(colorScheme == .dark ? Color(red: 0.945, green: 0.925, blue: 0.925) : Color(red: 0.129, green: 0.118, blue: 0.118)), style: FillStyle(eoFill: true))
                    context.fill(Path(CGRect(x: 8, y: 16, width: 16, height: 16)), with: .color(colorScheme == .dark ? Color(red: 0.294, green: 0.275, blue: 0.275) : Color(red: 0.812, green: 0.808, blue: 0.804)))
                }
            } else if let resource, let url = Bundle.main.url(forResource: resource, withExtension: "png", subdirectory: "ProviderIcons"), let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo).resizable().renderingMode(provider == .codexCLI ? .template : .original).scaledToFit()
            } else {
                Image(systemName: "cpu").resizable().scaledToFit()
            }
        }.frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let color = accent.flatMap(ProviderAccent.color) {
                    let dot = max(5, size * 0.34)
                    Circle().fill(color).frame(width: dot, height: dot)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .offset(x: dot * 0.3, y: dot * 0.3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Instance colors that tell two accounts of the same provider apart.
enum ProviderAccent {
    static let presets = ["#E5484D", "#F76B15", "#FFC53D", "#46A758", "#12A594", "#3E63DD", "#8E4EC6", "#D6409F"]
    static func color(_ hex: String) -> Color? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
