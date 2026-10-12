import SwiftUI

/// The app's mark. Packaged builds carry the rendered artwork; anything else shows the app icon.
struct PalladiumMark: View {
    var size: CGFloat = 160
    static let artwork: NSImage? = Bundle.main.url(forResource: "PalladiumMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        Image(nsImage: Self.artwork ?? NSApp.applicationIconImage).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
