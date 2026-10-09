import Foundation

// Manually packaged macOS apps keep resources inside their signed Contents folder.
// SwiftPM's native accessor only checks the app root and the original build path.
enum MathResourceBundle {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SwiftMath_SwiftMath", withExtension: "bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()
}
