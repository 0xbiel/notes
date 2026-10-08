import SwiftUI
import LectureCore

struct ProviderLogo: View {
    let provider: NotesAIProvider
    var size: CGFloat = 26
    @Environment(\.colorScheme) private var colorScheme

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
            } else if let url = Bundle.main.url(forResource: provider == .codexCLI ? "codex" : "antigravity", withExtension: "png", subdirectory: "ProviderIcons"), let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo).resizable().renderingMode(provider == .codexCLI ? .template : .original).scaledToFit()
            } else {
                Image(systemName: "cpu").resizable().scaledToFit()
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
