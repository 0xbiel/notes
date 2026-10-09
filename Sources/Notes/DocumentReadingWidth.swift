import Foundation

enum DocumentReadingWidth: String {
    case standard, wide
    func horizontalInset(viewport: CGFloat) -> CGFloat {
        let margin: CGFloat = viewport < 600 ? 22 : 40
        guard self == .standard else { return margin }
        return max(margin, (viewport - 680) / 2)
    }
}
