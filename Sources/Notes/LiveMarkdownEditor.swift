import AppKit
import SwiftUI

@MainActor private final class FoldingLayoutManager: NSLayoutManager, @preconcurrency NSLayoutManagerDelegate {
    var foldedRanges: [NSRange] = [] {
        didSet {
            guard foldedRanges != oldValue, let textStorage else { return }
            let full = NSRange(location: 0, length: textStorage.length)
            invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !foldedRanges.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for index in properties.indices where foldedRanges.contains(where: { NSLocationInRange(charIndexes[index], $0) }) {
            properties[index].insert(.null)
            changed = true
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }
}

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
    private struct CodeBlock {
        let id: String
        let range: NSRange
        let opening: NSRange
        let body: NSRange
        let closing: NSRange?
        let language: String
    }

    var liveEditing = true
    var savedScroll = NSPoint.zero
    var openLink: ((URL) -> Void)?
    private var styling = false
    private var renderedSource: String?
    private var renderedSelection = NSRange(location: NSNotFound, length: 0)
    private var renderedEditing = false
    private var codeBlocks: [CodeBlock] = []
    private var collapsedBlocks: Set<String> = []
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }

    override convenience init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = FoldingLayoutManager()
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
    private func blockRect(_ block: CodeBlock) -> NSRect? {
        guard block.range.length > 0, let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSRect(x: origin.x, y: origin.y + first.minY,
                      width: textContainer.size.width, height: last.maxY - first.minY)
    }

    private func foldedRange(for block: CodeBlock) -> NSRange? {
        guard block.body.length > 0 else { return nil }
        return block.body
    }

    func toggleCodeBlock(at index: Int) {
        guard codeBlocks.indices.contains(index), let folded = foldedRange(for: codeBlocks[index]), folded.length > 0 else { return }
        let block = codeBlocks[index]
        let id = block.id
        if collapsedBlocks.contains(id) {
            collapsedBlocks.remove(id)
        } else {
            let selection = selectedRange()
            if selection.location != NSNotFound &&
                (NSIntersectionRange(selection, block.range).length > 0 ||
                 (selection.length == 0 && selection.location >= block.range.location && selection.location < NSMaxRange(block.range))) {
                let afterBlock = min((string as NSString).length, NSMaxRange(block.range) + 1)
                setSelectedRange(NSRange(location: afterBlock, length: 0))
            }
            collapsedBlocks.insert(id)
        }
        renderedSource = nil
        renderMarkdown()
        (layoutManager as? FoldingLayoutManager)?.foldedRanges = codeBlocks.compactMap {
            collapsedBlocks.contains($0.id) ? foldedRange(for: $0) : nil
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, block) in codeBlocks.enumerated() {
            guard let card = blockRect(block) else { continue }
            let compact = collapsedBlocks.contains(block.id) && foldedRange(for: block)?.location == block.body.location
            let shift = compact ? max(0, (card.height - 35) / 2) : 0
            let header = NSRect(x: liveEditing ? card.maxX - 36 : card.minX, y: card.minY + shift,
                                width: liveEditing ? 36 : card.width, height: 35)
            if header.contains(point) { toggleCodeBlock(at: index); return }
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for block in codeBlocks {
            guard let card = blockRect(block) else { continue }
            let compact = collapsedBlocks.contains(block.id) && foldedRange(for: block)?.location == block.body.location
            let shift = compact ? max(0, (card.height - 35) / 2) : 0
            addCursorRect(NSRect(x: liveEditing ? card.maxX - 36 : card.minX, y: card.minY + shift,
                                 width: liveEditing ? 36 : card.width, height: 35), cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if layoutManager != nil {
            for block in codeBlocks {
                guard let card = blockRect(block) else { continue }
                guard card.intersects(dirtyRect) else { continue }
                let path = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
                (NSColor.textBackgroundColor.blended(withFraction: 0.07, of: .labelColor) ?? .controlBackgroundColor).setFill()
                path.fill()
                NSColor.separatorColor.withAlphaComponent(0.42).setStroke()
                path.lineWidth = 1
                path.stroke()
                let label = (block.language.isEmpty ? "TEXT" : block.language.uppercased()) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
                let selection = selectedRange()
                let editingFence = !collapsedBlocks.contains(block.id) && liveEditing && selection.location != NSNotFound &&
                    (NSIntersectionRange(selection, block.opening).length > 0 ||
                     (selection.length == 0 && selection.location >= block.opening.location && selection.location <= NSMaxRange(block.opening)))
                let folded = collapsedBlocks.contains(block.id) ? foldedRange(for: block) : nil
                let compact = folded?.location == block.body.location
                let headerShift = compact ? max(0, (card.height - 35) / 2) : 0
                let headerY = card.minY + 9 + headerShift + (compact ? 2 : 0)
                let labelX = editingFence ? card.maxX - label.size(withAttributes: attributes).width - 42 : card.minX + 15
                label.draw(at: NSPoint(x: labelX, y: headerY), withAttributes: attributes)
                let chevron = (collapsedBlocks.contains(block.id) ? "›" : "⌄") as NSString
                chevron.draw(at: NSPoint(x: card.maxX - 27, y: card.minY + 6 + headerShift), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
                var suffixX = card.maxX - 43
                if let folded, !editingFence {
                    let hidden = (string as NSString).substring(with: folded)
                    let lineCount = hidden.components(separatedBy: "\n").count - (hidden.hasSuffix("\n") ? 1 : 0)
                    let remainingLines = max(0, lineCount - 1)
                    if remainingLines > 0 {
                        let suffix = "… +\(remainingLines)" as NSString
                        suffixX -= suffix.size(withAttributes: attributes).width
                        suffix.draw(at: NSPoint(x: suffixX, y: headerY), withAttributes: attributes)
                    }
                }
                if compact && !editingFence {
                    let preview = (string as NSString).substring(with: block.body).components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty }) ?? ""
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byClipping
                    (preview as NSString).draw(in: NSRect(x: card.minX + 90, y: headerY,
                                                        width: max(0, suffixX - card.minX - 100), height: 18), withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style
                    ])
                }
            }
        }
        super.draw(dirtyRect)
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
    private func highlightCode(in range: NSRange, language: String, source: String, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let kind = language.lowercased()
        guard !kind.isEmpty, !["text", "txt", "plain", "plaintext"].contains(kind) else { return }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?.matches(in: source, range: range) ?? []
        }
        let keywords: [String]
        switch kind {
        case "swift":
            keywords = ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"]
        case "js", "jsx", "javascript", "ts", "tsx", "typescript":
            keywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "undefined", "var", "while", "yield"]
        case "py", "python":
            keywords = ["and", "as", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case "sh", "bash", "zsh", "shell":
            keywords = ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "return", "then", "while"]
        case "sql":
            keywords = ["AND", "AS", "BY", "CREATE", "DELETE", "FROM", "GROUP", "INSERT", "INTO", "JOIN", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "SET", "TABLE", "UPDATE", "VALUES", "WHERE"]
        default:
            keywords = []
        }
        let stringPattern = "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
        let strings = matches(stringPattern).map(\.range)
        let commentPattern: String
        switch kind {
        case "py", "python", "sh", "bash", "zsh", "shell", "yaml", "yml": commentPattern = "#[^\\n]*"
        case "sql": commentPattern = "--[^\\n]*|/\\*[\\s\\S]*?\\*/"
        case "html", "xml": commentPattern = "<!--[\\s\\S]*?-->"
        default: commentPattern = "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        }
        let comments = matches(commentPattern).map(\.range).filter { comment in
            !strings.contains { NSLocationInRange(comment.location, $0) }
        }
        let protected = strings + comments
        func isPlainCode(_ range: NSRange) -> Bool {
            !protected.contains { NSIntersectionRange($0, range).length > 0 }
        }
        if !keywords.isEmpty {
            let pattern = "\\b(?:" + keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b"
            let options: NSRegularExpression.Options = kind == "sql" ? [.caseInsensitive] : []
            for match in (try? NSRegularExpression(pattern: pattern, options: options))?.matches(in: source, range: range) ?? [] where isPlainCode(match.range) {
                storage.addAttributes([.foregroundColor: NSColor.systemBlue, .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)], range: match.range)
            }
        }
        for match in matches("\\b[0-9]+(?:\\.[0-9]+)?\\b") where isPlainCode(match.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
        }
        for token in strings {
            storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: token)
        }
        if kind == "json" {
            for match in matches("\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)") {
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
            }
        }
        for comment in comments {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: comment)
        }
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
        func hide(_ range: NSRange, context: NSRange, force: Bool = false) {
            guard range.length > 0, force || !visible(context) else { return }
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range)
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?.matches(in: string, range: full) ?? []
        }
        // Keep the source intact; use paragraph space for the header and inset body.
        var blocks: [CodeBlock] = []
        var occurrences: [String: Int] = [:]
        func codeBlock(range: NSRange, opening: NSRange, body: NSRange, closing: NSRange?, language: String) -> CodeBlock {
            let base = language + "\u{0}" + source.substring(with: body)
            let ordinal = occurrences[base, default: 0]
            occurrences[base] = ordinal + 1
            return CodeBlock(id: base + "\u{0}" + String(ordinal), range: range, opening: opening,
                             body: body, closing: closing, language: language)
        }
        var opening: (offset: Int, length: Int, language: String)?
        var offset = 0
        for line in string.components(separatedBy: "\n") {
            let count = line.utf16.count
            let fence = line.trimmingCharacters(in: .whitespaces)
            if let start = opening, fence.hasPrefix("```"), String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(codeBlock(range: NSRange(location: start.offset, length: offset + count - start.offset),
                                        opening: NSRange(location: start.offset, length: start.length),
                                        body: NSRange(location: min(start.offset + start.length + 1, offset), length: max(0, offset - start.offset - start.length - 1)),
                                        closing: NSRange(location: offset, length: count), language: start.language))
                opening = nil
            } else if opening == nil, fence.hasPrefix("```") {
                let language = fence.dropFirst(3).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                opening = (offset, count, language)
            }
            offset += count + 1
        }
        if let start = opening {
            blocks.append(codeBlock(range: NSRange(location: start.offset, length: source.length - start.offset),
                                    opening: NSRange(location: start.offset, length: start.length),
                                    body: NSRange(location: min(start.offset + start.length + 1, source.length), length: max(0, source.length - start.offset - start.length - 1)),
                                    closing: nil, language: start.language))
        }
        codeBlocks = blocks
        collapsedBlocks = collapsedBlocks.intersection(Set(blocks.map(\.id)))
        if liveEditing, active.location != NSNotFound {
            for block in blocks where collapsedBlocks.contains(block.id) {
                if let folded = foldedRange(for: block), active.location >= folded.location && active.location < NSMaxRange(folded) {
                    collapsedBlocks.remove(block.id)
                }
            }
        }
        var codeRanges = blocks.map(\.range)
        func inCode(_ range: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, range).length > 0 } }
        for block in blocks {
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: block.range)
            let header = NSMutableParagraphStyle()
            header.firstLineHeadIndent = 15
            header.headIndent = 15
            header.minimumLineHeight = 35
            storage.addAttribute(.paragraphStyle, value: header, range: block.opening)
            let body = NSMutableParagraphStyle()
            body.firstLineHeadIndent = 15
            body.headIndent = 15
            body.tailIndent = -15
            body.minimumLineHeight = 23
            body.lineSpacing = 2
            if block.body.length > 0 { storage.addAttribute(.paragraphStyle, value: body, range: block.body) }
            if let closing = block.closing {
                let footer = NSMutableParagraphStyle()
                footer.minimumLineHeight = 11
                storage.addAttribute(.paragraphStyle, value: footer, range: closing)
                hide(closing, context: closing, force: collapsedBlocks.contains(block.id))
            }
            hide(block.opening, context: block.opening, force: collapsedBlocks.contains(block.id))
            highlightCode(in: block.body, language: block.language, source: string, storage: storage)
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
        (layoutManager as? FoldingLayoutManager)?.foldedRanges = blocks.compactMap {
            collapsedBlocks.contains($0.id) ? foldedRange(for: $0) : nil
        }
        // Selection callbacks can restyle text during an AppKit character edit.
        // In that path, font changes outside the edited paragraph can retain
        // glyph IDs from the previous font. Regenerate them after styling.
        layoutManager?.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }
}
