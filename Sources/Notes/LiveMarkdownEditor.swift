import AppKit
import SwiftUI

/// The NSTextStorage always contains exact Markdown. Presentation changes only
/// attributes; it never replaces characters with a rendered representation.
struct LiveMarkdownEditor: NSViewRepresentable {
    var documentID: String
    var text: String
    var editing: Bool
    var heading: String? = nil
    var onChange: (String) -> Void
    var onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, scroll: scroll)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        // Each note retains its own undo manager, selection and scroll position.
        var editors: [String: MarkdownTextView] = [:]
        var currentID: String?
        var owner: LiveMarkdownEditor?
        var changing = false
        var lastHeading: String?
        func update(_ owner: LiveMarkdownEditor, scroll: NSScrollView) {
            self.owner = owner
            let view: MarkdownTextView
            if let existing = editors[owner.documentID] { view = existing }
            else {
                view = MarkdownTextView(frame: scroll.bounds)
                view.delegate = self
                view.string = owner.text
                editors[owner.documentID] = view
            }
            if currentID != owner.documentID {
                if let previous = scroll.documentView as? MarkdownTextView { previous.savedScroll = scroll.contentView.bounds.origin }
                // Fence off late callbacks from the outgoing text view before detaching it.
                currentID = owner.documentID
                scroll.documentView = view
                lastHeading = nil
                view.frame.size.width = scroll.contentSize.width
                scroll.contentView.scroll(to: view.savedScroll)
            }
            // Never replace marked text during an input-method composition.
            if view.string != owner.text && !view.hasMarkedText() {
                changing = true
                let selection = view.selectedRange()
                view.string = owner.text
                view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
                view.undoManager?.removeAllActions()
                changing = false
            }
            view.isEditable = owner.editing
            view.liveEditing = owner.editing
            view.setAccessibilityLabel(owner.editing ? "Editar nota, vista previa Markdown" : "Ver nota")
            view.openLink = owner.onLink
            view.renderMarkdown()
            if let heading = owner.heading, lastHeading != heading {
                let pattern = "(?m)^#{1,6}[ \t]+" + NSRegularExpression.escapedPattern(for: heading) + "[ \t]*$"
                if let match = (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: view.string, range: NSRange(location: 0, length: view.string.utf16.count)) {
                    view.scrollRangeToVisible(match.range)
                    lastHeading = heading
                }
            } else if owner.heading == nil { lastHeading = nil }
        }
        func textDidChange(_ notification: Notification) {
            guard !changing, let view = notification.object as? MarkdownTextView,
                  let currentID, editors[currentID] === view else { return }
            // Publish even marked text so switching documents cannot lose input.
            owner?.onChange(view.string)
            view.renderMarkdown()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !changing, let view = notification.object as? MarkdownTextView,
                  let currentID, editors[currentID] === view else { return }
            view.renderMarkdown()
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { owner?.onLink(url) }
            else if let value = link as? String, let url = URL(string: value) { owner?.onLink(url) }
            return true // All links go through the existing privacy-aware router.
        }
    }
}

@MainActor final class MarkdownTextView: NSTextView {
    var liveEditing = true
    var savedScroll = NSPoint.zero
    var openLink: ((URL) -> Void)?
    private var styling = false
    private var renderedSource: String?
    private var renderedSelection = NSRange(location: NSNotFound, length: 0)
    private var renderedEditing = false
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }

    override convenience init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        self.init(frame: frame, textContainer: container)
        isRichText = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = true
        textContainerInset = NSSize(width: frame.width < 600 ? 22 : 40, height: 28)
        drawsBackground = false
        font = .systemFont(ofSize: 16)
        textColor = .labelColor
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainerInset = NSSize(width: newSize.width < 600 ? 22 : 40, height: 28)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderedSource = nil
        renderMarkdown()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("b", [.command]): toggleMarkdownBold(nil); return true
        case ("i", [.command]): toggleMarkdownItalic(nil); return true
        case ("k", [.command, .shift]): toggleMarkdownCode(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    @objc func toggleMarkdownBold(_ sender: Any?) { toggleMarker("**") }
    @objc func toggleMarkdownItalic(_ sender: Any?) { toggleMarker("*") }
    @objc func toggleMarkdownCode(_ sender: Any?) { toggleMarker("`") }
    private func toggleMarker(_ marker: String) {
        guard isEditable, !hasMarkedText() else { return }
        let selection = selectedRange()
        let ns = string as NSString
        let count = marker.utf16.count
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return }
        breakUndoCoalescing()
        if selection.location >= count, NSMaxRange(selection) + count <= ns.length,
           ns.substring(with: NSRange(location: selection.location - count, length: count)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: count)) == marker {
            insertText(ns.substring(with: selection), replacementRange: NSRange(location: selection.location - count, length: selection.length + count * 2))
            setSelectedRange(NSRange(location: selection.location - count, length: selection.length))
        } else {
            insertText(marker + ns.substring(with: selection) + marker, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + count, length: selection.length))
        }
        breakUndoCoalescing()
    }
    @objc func undo(_ sender: Any?) { if isEditable { documentUndo.undo() } }
    @objc func redo(_ sender: Any?) { if isEditable { documentUndo.redo() } }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return isEditable && documentUndo.canUndo }
        if item.action == #selector(redo(_:)) { return isEditable && documentUndo.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { super.insertNewline(sender); return }
        let source = string as NSString
        let position = selectedRange().location
        let line = source.lineRange(for: NSRange(location: position, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: position - line.location))
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*)([-+*]|[0-9]+\\.)( \\[[ xX]\\])? +"),
              let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { super.insertNewline(sender); return }
        let ns = before as NSString
        if match.range.length == ns.length {
            insertText("", replacementRange: NSRange(location: line.location, length: before.utf16.count))
            return
        }
        let indent = ns.substring(with: match.range(at: 1))
        var marker = ns.substring(with: match.range(at: 2))
        if let number = Int(marker.dropLast()), marker.hasSuffix("."), number < Int.max { marker = "\(number + 1)." }
        let check = match.range(at: 3).location == NSNotFound ? "" : " [ ]"
        insertText("\n" + indent + marker + check + " ", replacementRange: selectedRange())
    }
    func renderMarkdown() {
        guard !styling, !hasMarkedText(), let storage = textStorage else { return }
        styling = true
        defer { styling = false }
        let source = string as NSString
        let full = NSRange(location: 0, length: source.length)
        let active = liveEditing ? selectedRange() : NSRange(location: NSNotFound, length: 0)
        guard renderedSource != string || renderedSelection != active || renderedEditing != liveEditing else { return }
        renderedSource = string; renderedSelection = active; renderedEditing = liveEditing
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 0
        // Attribute edits are presentation only and never enter the undo stack.
        documentUndo.disableUndoRegistration()
        storage.beginEditing()
        storage.setAttributes([.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
        func visible(_ range: NSRange) -> Bool {
            guard active.location != NSNotFound else { return false }
            if active.length == 0 { return active.location >= range.location && active.location <= NSMaxRange(range) }
            return NSIntersectionRange(active, range).length > 0
        }
        func hide(_ range: NSRange, context: NSRange) {
            guard range.length > 0, !visible(context) else { return }
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range)
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?.matches(in: string, range: full) ?? []
        }
        // Code is excluded from inline parsing, including incomplete fences.
        var codeRanges: [NSRange] = []
        var fenceStart: Int?
        var offset = 0
        for line in string.components(separatedBy: "\n") {
            let count = line.utf16.count
            if line.hasPrefix("```") {
                if let start = fenceStart {
                    codeRanges.append(NSRange(location: start, length: offset + count - start)); fenceStart = nil
                } else { fenceStart = offset }
            }
            offset += count + 1
        }
        if let start = fenceStart { codeRanges.append(NSRange(location: start, length: source.length - start)) }
        func inCode(_ range: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, range).length > 0 } }
        for range in codeRanges {
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.10)], range: range)
        }
        for match in matches("^```[^\\n]*$") {
            hide(match.range, context: match.range)
        }
        for match in matches("^(#{1,6})[ \\t]+(.+)$") where !inCode(match.range) {
            let level = match.range(at: 1).length
            let sizes: [CGFloat] = [32, 25, 21, 18, 17, 16]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[level - 1], weight: .semibold), range: match.range)
            hide(NSRange(location: match.range.location, length: match.range(at: 2).location - match.range.location), context: match.range)
        }
        for match in matches("^>[ \\t]?(.*)$") where !inCode(match.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
            hide(NSRange(location: match.range.location, length: match.range(at: 1).location - match.range.location), context: match.range)
        }
        for match in matches("(?<!\\\\)`([^`\\n]+)`") where !inCode(match.range) {
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.1)], range: match.range(at: 1))
            hide(NSRange(location: match.range.location, length: 1), context: match.range)
            hide(NSRange(location: NSMaxRange(match.range) - 1, length: 1), context: match.range)
            codeRanges.append(match.range)
        }
        let formats: [(String, NSAttributedString.Key, Any, Int)] = [
            ("(?<!\\\\)\\*\\*([^*\\n]+)\\*\\*", .font, NSFont.boldSystemFont(ofSize: 16), 2),
            ("(?<![\\\\*])\\*([^*\\n]+)\\*(?!\\*)", .font, NSFontManager.shared.convert(.systemFont(ofSize: 16), toHaveTrait: .italicFontMask), 1),
            ("(?<!\\\\)~~([^~\\n]+)~~", .strikethroughStyle, NSUnderlineStyle.single.rawValue, 2)
        ]
        for (pattern, key, value, count) in formats {
            for match in matches(pattern) where !inCode(match.range) {
                if key == .font, let requested = value as? NSFont {
                    let current = storage.attribute(.font, at: match.range(at: 1).location, effectiveRange: nil) as? NSFont ?? requested
                    let traits = NSFontManager.shared.traits(of: requested)
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: traits), range: match.range(at: 1))
                } else { storage.addAttribute(key, value: value, range: match.range(at: 1)) }
                hide(NSRange(location: match.range.location, length: count), context: match.range)
                hide(NSRange(location: NSMaxRange(match.range) - count, length: count), context: match.range)
            }
        }
        for match in matches("(?<!\\\\)\\[([^]\\n]+)\\]\\(([^)\\n]+)\\)") where !inCode(match.range) {
            guard let url = URL(string: source.substring(with: match.range(at: 2))) else { continue }
            storage.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: match.range(at: 1))
            hide(NSRange(location: match.range.location, length: 1), context: match.range)
            hide(NSRange(location: NSMaxRange(match.range(at: 1)), length: NSMaxRange(match.range) - NSMaxRange(match.range(at: 1))), context: match.range)
        }
        for match in matches("\\[\\[([^]\\n]+)\\]\\]") where !inCode(match.range) {
            let content = source.substring(with: match.range(at: 1))
            let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            var url = URLComponents(); url.scheme = "derecho-note"; url.host = "open"
            url.queryItems = [.init(name: "target", value: String(parts[0]))]
            let labelStart = parts.count == 2 ? match.range(at: 1).location + String(parts[0]).utf16.count + 1 : match.range(at: 1).location
            let label = NSRange(location: labelStart, length: NSMaxRange(match.range(at: 1)) - labelStart)
            if let link = url.url { storage.addAttributes([.link: link, .foregroundColor: NSColor.linkColor], range: label) }
            hide(NSRange(location: match.range.location, length: labelStart - match.range.location), context: match.range)
            hide(NSRange(location: NSMaxRange(label), length: 2), context: match.range)
        }
        storage.endEditing()
        documentUndo.enableUndoRegistration()
        typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }
}
