import SwiftUI
import AppKit

/// Color only the text insertion point; navigation controls retain their styling.
struct NotebookAccentCaret: NSViewRepresentable {
    @AppStorage("notes.accent") private var stored = ""
    func makeNSView(context: Context) -> NotebookAccentCaretObserver { NotebookAccentCaretObserver() }
    func updateNSView(_ view: NotebookAccentCaretObserver, context: Context) {
        view.caretColor = NSColor(NotebookAccent.color(stored))
        view.updateCurrentEditor()
    }
}

final class NotebookAccentCaretObserver: NSView {
    var caretColor = NSColor.controlAccentColor
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(editingBegan), name: NSText.didBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editingBegan), name: NSControl.textDidBeginEditingNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateCurrentEditor() }
    func updateCurrentEditor() {
        if let editor = window?.firstResponder as? NSTextView { editor.insertionPointColor = caretColor }
    }
    @objc private func editingBegan(_ notification: Notification) {
        if let text = notification.object as? NSTextView, text.window === window, window != nil {
            text.insertionPointColor = caretColor
        } else if let field = notification.object as? NSTextField, field.window === window, window != nil {
            (field.currentEditor() as? NSTextView)?.insertionPointColor = caretColor
        }
    }
}
