import SwiftUI

private struct NotebookChatExpansionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (CGRect) -> Void)? = nil
}

private struct NotebookChatExpansionAnchorKey: EnvironmentKey {
    static let defaultValue: UnitPoint? = nil
}

extension EnvironmentValues {
    var expandNotebookChat: (@MainActor @Sendable (CGRect) -> Void)? {
        get { self[NotebookChatExpansionKey.self] }
        set { self[NotebookChatExpansionKey.self] = newValue }
    }
    /// Where the floating chat sat when it was expanded, relative to the page.
    var notebookChatExpansionAnchor: UnitPoint? {
        get { self[NotebookChatExpansionAnchorKey.self] }
        set { self[NotebookChatExpansionAnchorKey.self] = newValue }
    }
}

/// Grows the full-page chat out of the floating chat as a render transform, so nothing inside relayouts.
struct NotebookChatReveal: ViewModifier {
    @Environment(\.notebookChatExpansionAnchor) private var anchor
    @State private var revealed = true
    @State private var origin = UnitPoint.center
    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed ? 1 : 0.92, anchor: origin)
            .opacity(revealed ? 1 : 0)
            .onAppear {
                guard let anchor else { return }
                origin = anchor; revealed = false
                withAnimation(.spring(duration: 0.38, bounce: 0)) { revealed = true }
            }
    }
}
