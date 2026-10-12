import AppKit
import SwiftUI
import LectureCore

@MainActor private final class FoldingLayoutManager: NSLayoutManager, @preconcurrency NSLayoutManagerDelegate {
    var math: [Int: RenderedMarkdownMath] = [:]
    var images: [Int: RenderedMarkdownImage] = [:]
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
        guard !foldedRanges.isEmpty || !math.isEmpty || !images.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for index in properties.indices {
            if math[charIndexes[index]] != nil || images[charIndexes[index]] != nil { properties[index] = .controlCharacter; changed = true }
            else if foldedRanges.contains(where: { NSLocationInRange(charIndexes[index], $0) }) { properties[index].insert(.null); changed = true }
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        math[charIndex] == nil && images[charIndex] == nil ? action : .whitespace
    }
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if let image = images[charIndex] { return NSRect(origin: .zero, size: image.size) }
        guard let render = math[charIndex] else { return .zero }
        return NSRect(x: 0, y: -render.descent, width: render.size.width + 2, height: render.size.height)
    }

}

@MainActor final class MarkdownScrollView: NSScrollView {
    let sectionState = MarkdownSectionState()
    private var sectionHost: MarkdownSectionHostingView?
    private var sectionSource: String?
    private var sectionRefreshPending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = MarkdownSectionHostingView(rootView: MarkdownSectionIndicator(state: sectionState))
        host.setAccessibilityIdentifier("document.sectionIndicator")
        addSubview(host)
        sectionHost = host
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sectionBoundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        sectionState.navigate = { [weak self] section in self?.navigate(to: section) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func sectionBoundsChanged() { scheduleSectionRefresh() }

    func scheduleSectionRefresh() {
        guard !sectionRefreshPending else { return }
        sectionRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sectionRefreshPending = false
            self.refreshSectionIndicator()
        }
    }

    func refreshSectionIndicator() {
        guard let view = documentView as? MarkdownTextView,
              let manager = view.layoutManager, let container = view.textContainer else {
            sectionHost?.isHidden = true; return
        }
        if sectionSource != view.string {
            sectionSource = view.string
            sectionState.sections = MarkdownSection.parse(view.string)
        }
        sectionHost?.isHidden = sectionState.sections.isEmpty
        if sectionState.accent != view.taskAccent { sectionState.accent = view.taskAccent }
        manager.ensureLayout(for: container)
        let top = contentView.bounds.minY + 32
        let atBottom = contentView.bounds.minY > 0 && contentView.bounds.maxY >= view.frame.height - 1
        let current = atBottom ? sectionState.sections.last : (sectionState.sections.last { sectionY($0, view: view) <= top } ?? sectionState.sections.first)
        if sectionState.currentID != current?.id { sectionState.currentID = current?.id }
        let positions = sectionState.sections.map { sectionY($0, view: view) }
        let visible = MarkdownSectionNavigation.visibleIDs(sections: sectionState.sections, positions: positions,
                                                          documentHeight: view.frame.height, viewport: contentView.bounds)
        if sectionState.visibleIDs != visible { sectionState.visibleIDs = visible }
        positionSectionIndicator()
    }

    private func sectionY(_ section: MarkdownSection, view: MarkdownTextView) -> CGFloat {
        guard let manager = view.layoutManager else { return 0 }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: section.range.location, length: 1), actualCharacterRange: nil)
        return manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY + view.textContainerOrigin.y
    }

    func navigate(to section: MarkdownSection) {
        guard let view = documentView as? MarkdownTextView else { return }
        let y = max(0, sectionY(section, view: view) - 28)
        let maxY = max(0, view.frame.height - contentView.bounds.height + contentInsets.bottom)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(y, maxY)))
        reflectScrolledClipView(contentView)
        refreshSectionIndicator()
    }

    private func positionSectionIndicator() {
        let available = max(0, bounds.height - contentInsets.bottom)
        let height = min(max(112, CGFloat(sectionState.overview.count) * 11 + 47), min(280, available))
        let y = (available - height) / 2 + (isFlipped ? 0 : contentInsets.bottom)
        sectionHost?.frame = NSRect(x: bounds.maxX - 302, y: y, width: 280, height: height)
    }

    private var pendingOrigin: NSPoint?
    private var restoring = false
    private var restorationGeneration = 0

    func restoreScroll(to origin: NSPoint, replacingPending: Bool) {
        if replacingPending || pendingOrigin == nil { pendingOrigin = origin }
        restorationGeneration += 1
        let generation = restorationGeneration
        needsLayout = true
        layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.restorationGeneration == generation else { return }
            if self.applyPendingScroll() { self.pendingOrigin = nil }
        }
    }

    override func layout() {
        super.layout()
        _ = applyPendingScroll()
        positionSectionIndicator()
        scheduleSectionRefresh()
    }

    @discardableResult private func applyPendingScroll() -> Bool {
        guard !restoring, let origin = pendingOrigin,
              contentSize.width > 0, contentSize.height > 0,
              let view = documentView as? MarkdownTextView else { return false }
        restoring = true
        view.frame.size.width = contentSize.width
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        view.setFrameOrigin(.zero)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        restoring = false
        return true
    }
}

/// The NSTextStorage always contains exact Markdown. Presentation changes only
/// attributes; it never replaces characters with a rendered representation.
struct LiveMarkdownEditor: NSViewRepresentable {
    var documentID: String
    var text: String
    var editing: Bool
    var heading: String? = nil
    var bottomInset: CGFloat = 0
    var imageDirectory: URL? = nil
    var imageRoot: URL? = nil
    var importImage: ((Data, String) throws -> URL)? = nil
    var onChange: (String) -> Void
    var onLink: (URL) -> Void
    var onTaskToggle: ((String) -> Void)? = nil
    @AppStorage("notes.accent") private var storedAccent = ""
    @AppStorage("notes.documentWidth") private var storedWidth = "wide"

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownScrollView()
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
            if currentID != owner.documentID || !owner.editing { (scroll.documentView as? MarkdownTextView)?.finishInlineTableCell() }
            self.owner = owner
            scroll.automaticallyAdjustsContentInsets = false
            let switching = currentID != owner.documentID
            let previousOrigin = scroll.contentView.bounds.origin
            let view: MarkdownTextView
            if let existing = editors[owner.documentID] { view = existing }
            else {
                view = MarkdownTextView(frame: scroll.bounds)
                view.delegate = self
                view.string = owner.text
                editors[owner.documentID] = view
            }
            if switching {
                if let previous = scroll.documentView as? MarkdownTextView { previous.savedScroll = scroll.contentView.bounds.origin }
                // Fence off late callbacks from the outgoing text view before detaching it.
                currentID = owner.documentID
                scroll.documentView = view
                lastHeading = nil
                view.frame.size.width = scroll.contentSize.width
            }
            // Never replace marked text during an input-method composition.
            if view.string != owner.text && !view.hasMarkedText() {
                changing = true
                view.finishInlineTableCell()
                view.tableSelection = nil
                let selection = view.selectedRange()
                view.string = owner.text
                view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
                view.undoManager?.removeAllActions()
                changing = false
            }
            view.isEditable = owner.editing
            view.imageDirectory = owner.imageDirectory
            view.imageRoot = owner.imageRoot
            view.importImage = owner.importImage
            view.liveEditing = owner.editing
            view.setAccessibilityLabel(owner.editing ? "Editar nota, vista previa Markdown" : "Ver nota")
            view.openLink = owner.onLink
            view.readingWidth = DocumentReadingWidth(rawValue: owner.storedWidth) ?? .wide
            view.taskAccent = NSColor(NotebookAccent.color(owner.storedAccent))
            view.didToggleTask = { [weak self, weak view] in
                guard let self, let view, let currentID = self.currentID, self.editors[currentID] === view else { return }
                self.owner?.onTaskToggle?(view.string)
            }
            view.renderMarkdown()
            // Attach and lay out the flipped text view before adjusting insets.
            // Otherwise an initially empty clip view can open a long note halfway down.
            let insetChanged = scroll.contentInsets.bottom != owner.bottomInset
            if insetChanged { scroll.contentInsets.bottom = owner.bottomInset }
            if switching || insetChanged {
                let origin = switching ? view.savedScroll : previousOrigin
                if let markdown = scroll as? MarkdownScrollView { markdown.restoreScroll(to: origin, replacingPending: switching) }
                else {
                    if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
                    view.sizeToFit()
                    view.setFrameOrigin(.zero)
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
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

    struct TaskItem {
        let marker: NSRange
        let state: NSRange
        let content: NSRange
        let indent: CGFloat
        let checked: Bool
    }
    private(set) var taskItems: [TaskItem] = []
    var readingWidth = DocumentReadingWidth.wide {
        didSet {
            guard readingWidth != oldValue else { return }
            updateReadingInsets()
            renderedSource = nil; renderMarkdown()
        }
    }
    private func updateReadingInsets() {
        let inset = readingWidth.horizontalInset(viewport: frame.width)
        let size = NSSize(width: inset, height: 28)
        if textContainerInset != size { textContainerInset = size }
    }
    var taskAccent = NSColor.controlAccentColor {
        didSet {
            // NSTextView's link attributes override the text-storage foreground.
            linkTextAttributes = [.foregroundColor: taskAccent, .underlineStyle: NSUnderlineStyle.single.rawValue]
            insertionPointColor = taskAccent
            if taskAccent != oldValue { renderedSource = nil; renderMarkdown() }
            needsDisplay = true
        }
    }
    var didToggleTask: (() -> Void)?
    var liveEditing = true
    var savedScroll = NSPoint.zero
    var openLink: ((URL) -> Void)?
    private var styling = false
    private var renderedSource: String?
    private var renderedSelection = NSRange(location: NSNotFound, length: 0)
    private var renderedEditing = false
    private var codeBlocks: [CodeBlock] = []
    private var inlineCode: [NSRange] = []
    private(set) var tableBlocks: [MarkdownTableBlock] = []
    var imageDirectory: URL? { didSet { if imageDirectory != oldValue { renderedSource = nil } } }
    var imageRoot: URL? { didSet { if imageRoot != oldValue { renderedSource = nil } } }
    private(set) var renderedImages: [RenderedMarkdownImage] = []
    var selectedImageLocation: Int?
    var importImage: ((Data, String) throws -> URL)?
    private var imageViews: [MarkdownImageView] = []
    private(set) var renderedMath: [RenderedMarkdownMath] = []
    private(set) var renderedTables: [RenderedMarkdownTable] = []
    var contextTable: MarkdownTableBlock?
    var contextTableSource = ""
    var contextTableCell: (row: Int, column: Int)?
    var inlineTableCell: InlineTableCellEdit?
    var tableControls: [NSButton] = []
    var tableSelection: TableCellSelection?
    private var collapsedBlocks: Set<String> = []
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }

    override convenience init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = FoldingLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        self.init(frame: frame, textContainer: container)
        registerForDraggedTypes([.fileURL, .png, .tiff])
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
        let changedWidth = frame.width != newSize.width
        super.setFrameSize(newSize)
        updateReadingInsets()
        if changedWidth { renderedSource = nil; renderMarkdown() }
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
        } + renderedTables.compactMap(\.foldedRange) + renderedMath.map(\.foldedRange) + renderedImages.map(\.foldedRange)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        selectedImageLocation = nil; updateImageSelection()
        finishInlineTableCell()
        let point = convert(event.locationInWindow, from: nil)
        // A click on a link inside a table follows it; while editing, a plain click selects the cell and Command-click follows.
        if !isEditable || event.modifierFlags.contains(.command), let hit = tableCell(at: point), let rect = tableRect(hit.table),
           let url = hit.table.layout.link(at: NSPoint(x: point.x - rect.minX, y: point.y - rect.minY)) { openLink?(url); return }
        if isEditable, let hit = tableCell(at: point) {
            selectTableCell(hit.table, cellIndex: hit.index, extending: event.modifierFlags.contains(.shift))
            window?.makeFirstResponder(self)
            if event.clickCount > 1 { beginInlineTableCell(hit.table, cellIndex: hit.index) }; return
        }
        tableSelection = nil; needsDisplay = true
        if let index = taskItems.indices.first(where: { taskRect(taskItems[$0])?.insetBy(dx: -4, dy: -4).contains(point) == true }) {
            toggleTask(at: index); return
        }
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
        if !hasMarkedText() {
            for task in taskItems { if let rect = taskRect(task) { addCursorRect(rect.insetBy(dx: -4, dy: -4), cursor: .pointingHand) } }
        }
        for block in codeBlocks {
            guard let card = blockRect(block) else { continue }
            let compact = collapsedBlocks.contains(block.id) && foldedRange(for: block)?.location == block.body.location
            let shift = compact ? max(0, (card.height - 35) / 2) : 0
            addCursorRect(NSRect(x: liveEditing ? card.maxX - 36 : card.minX, y: card.minY + shift,
                                 width: liveEditing ? 36 : card.width, height: 35), cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let codeFill = NSColor.textBackgroundColor.blended(withFraction: 0.07, of: .labelColor) ?? .controlBackgroundColor
        let codeBorder = NSColor.separatorColor.withAlphaComponent(0.42)
        if let layoutManager, let textContainer {
            for range in inlineCode {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                    // Keep the card within the normal line height, including wrapped snippets.
                    let height = min(rect.height, layoutManager.defaultLineHeight(for: .monospacedSystemFont(ofSize: 14, weight: .regular)) + 2)
                    let card = NSRect(x: rect.minX + self.textContainerOrigin.x - 3,
                        y: rect.midY + self.textContainerOrigin.y - height / 2, width: rect.width + 6, height: height)
                    guard card.intersects(dirtyRect) else { return }
                    let path = NSBezierPath(roundedRect: card, xRadius: 4, yRadius: 4)
                    codeFill.setFill(); path.fill()
                    codeBorder.setStroke(); path.lineWidth = 0.7; path.stroke()
                }
            }
            for block in codeBlocks {
                guard let card = blockRect(block) else { continue }
                guard card.intersects(dirtyRect) else { continue }
                let path = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
                codeFill.setFill()
                path.fill()
                codeBorder.setStroke()
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
        positionImageViews()
        for render in renderedMath {
            if let rect = mathRect(render), rect.intersects(dirtyRect) {
                render.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        for table in renderedTables {
            if let rect = tableRect(table), rect.intersects(dirtyRect) { table.layout.draw(at: rect.origin); drawTableSelection(table, at: rect) }
        }
        for task in taskItems {
            guard let rect = taskRect(task), rect.intersects(dirtyRect) else { continue }
            let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if task.checked { taskAccent.setFill(); box.fill() }
            else { NSColor.secondaryLabelColor.setStroke(); box.lineWidth = 1.3; box.stroke() }
            if task.checked {
                let check = NSBezierPath(); check.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
                check.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 3))
                check.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3))
                NSColor.white.setStroke(); check.lineWidth = 1.7; check.lineCapStyle = .round; check.stroke()
            }
        }
    }
    func mathRect(_ render: RenderedMarkdownMath) -> NSRect? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: render.span.range.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = manager.location(forGlyphAt: glyph)
        let y = render.span.display ? max(0, (line.height - render.size.height) / 2) : max(0, min(location.y - render.ascent, line.height - render.size.height))
        return NSRect(x: textContainerOrigin.x + line.minX + location.x,
                      y: textContainerOrigin.y + line.minY + y,
                      width: render.size.width, height: render.size.height)
    }
    private func taskRect(_ item: TaskItem) -> NSRect? {
        guard let layoutManager, let textContainer, item.content.location < (string as NSString).length else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: item.content.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: textContainerOrigin.x + item.indent, y: textContainerOrigin.y + line.minY + 4, width: 14, height: 14)
    }
    @objc func toggleMarkdownTask(_ sender: Any?) {
        let location = selectedRange().location
        if let index = taskItems.firstIndex(where: { NSLocationInRange(location, NSRange(location: $0.marker.location, length: NSMaxRange($0.content) - $0.marker.location + 1)) }) { toggleTask(at: index) }
    }
    func toggleTask(at index: Int) {
        guard !hasMarkedText(), taskItems.indices.contains(index) else { return }
        let wasEditable = isEditable
        isEditable = true
        defer { isEditable = wasEditable }
        let item = taskItems[index]
        breakUndoCoalescing()
        insertText(item.checked ? " " : "x", replacementRange: item.state)
        breakUndoCoalescing()
        renderedSource = nil; renderMarkdown()
        didToggleTask?()
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
        if item.action == #selector(copy(_:)), selectedImageLocation != nil || selectedTableText() != nil { return true }
        if item.action == #selector(undo(_:)) { return isEditable && documentUndo.canUndo }
        if item.action == #selector(redo(_:)) { return isEditable && documentUndo.canRedo }
        if item.action == #selector(visualTableMenuAction(_:)) || item.action == #selector(insertMarkdownTable(_:)) || item.action == #selector(editMarkdownTable(_:)) { return isEditable && !hasMarkedText() }
        return super.validateUserInterfaceItem(item)
    }
    override func paste(_ sender: Any?) {
        if insertImages(from: .general) { return }
        selectedImageLocation = nil; updateImageSelection()
        if tableSelection != nil { if !pasteTableCells(NSPasteboard.general.string(forType: .string) ?? "") { NSSound.beep() }; return }; pasteAsPlainText(sender)
    }
    override func copy(_ sender: Any?) {
        if selectedImageLocation != nil { copySelectedImage(); return }
        if let text = selectedTableText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } else { super.copy(sender) }
    }
    override func mouseDragged(with event: NSEvent) {
        if tableSelection != nil, let hit = tableCell(at: convert(event.locationInWindow, from: nil)) { selectTableCell(hit.table, cellIndex: hit.index, extending: true) } else if tableSelection == nil { super.mouseDragged(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if selectedImageLocation != nil {
            if event.keyCode == 51 || event.keyCode == 117 { removeSelectedImage(); return }
            let image = renderedImages.first { $0.range.location == selectedImageLocation }
            selectedImageLocation = nil; updateImageSelection()
            if event.keyCode == 53 { return }
            if let image { setSelectedRange(NSRange(location: min(string.utf16.count, NSMaxRange(image.range) + 1), length: 0)) }
        }
        if handleTableKey(event) { return }; super.keyDown(with: event)
    }
    override func cut(_ sender: Any?) {
        if selectedImageLocation != nil { copySelectedImage(); removeSelectedImage() } else { super.cut(sender) }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isEditable && DocumentImageInput.containsImage(sender.draggingPasteboard) { return .copy }
        if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil { return [] }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if DocumentImageInput.containsImage(sender.draggingPasteboard) {
            return insertImages(from: sender.draggingPasteboard, at: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)))
        }
        if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil { return false }
        return super.performDragOperation(sender)
    }
    func tableRect(_ table: RenderedMarkdownTable) -> NSRect? {
        guard let layoutManager, let textContainer, table.firstLine.location < (string as NSString).length else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: table.firstLine.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y + line.minY + 4, width: table.layout.width, height: table.layout.height)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        finishInlineTableCell()
        let menu = super.menu(for: event) ?? NSMenu()
        guard isEditable, !hasMarkedText() else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        contextTable = renderedTables.first(where: { tableRect($0)?.contains(point) == true })?.block
            ?? tableBlocks.first(where: { NSLocationInRange(characterIndexForInsertion(at: point), $0.range) })
        contextTableSource = string
        contextTableCell = tableCell(at: point).map { hit in
            selectTableCell(hit.table, cellIndex: hit.index, extending: false)
            let cell = hit.table.block.table.cells[hit.index]; return (cell.row, cell.column)
        }
        menu.addItem(.separator())
        let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
        if contextTable != nil {
            addVisualTableMenuItems(to: menu)
            let edit = NSMenuItem(title: english ? "Edit table…" : "Editar tabla…", action: #selector(editMarkdownTable(_:)), keyEquivalent: "")
            edit.target = self; menu.addItem(edit)
        }
        let insert = NSMenuItem(title: english ? "Insert table…" : "Insertar tabla…", action: #selector(insertMarkdownTable(_:)), keyEquivalent: "")
        insert.target = self; menu.addItem(insert)
        return menu
    }
    @objc func insertMarkdownTable(_ sender: Any?) { presentTableEditor(nil) }
    @objc func editMarkdownTable(_ sender: Any?) {
        let table = contextTable ?? tableBlocks.first(where: { NSLocationInRange(selectedRange().location, $0.range) })
        if let table { presentTableEditor(table) }
    }
    private func presentTableEditor(_ block: MarkdownTableBlock?) {
        guard isEditable, !hasMarkedText(), let window, window.attachedSheet == nil else { return }
        let original = string, range = block?.range ?? selectedRange()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let initialRow = block == nil ? 0 : min(contextTableCell?.row ?? tableSelection?.row ?? 0, (block?.table.rows ?? 1) - 1)
        let initialColumn = block == nil ? 0 : min(contextTableCell?.column ?? tableSelection?.column ?? 0, (block?.table.columns ?? 1) - 1)
        panel.contentView = NSHostingView(rootView: MarkdownTableEditingSheet(table: block?.table ?? MarkdownTable(), save: { [weak self, weak panel] table in
            guard let self, let panel else { return }
            guard self.applyMarkdownTable(table, replacing: range, expectedSource: original, inserting: block == nil) else { NSSound.beep(); return }
            window.endSheet(panel); panel.close(); panel.contentView = nil
        }, cancel: { [weak panel] in if let panel { window.endSheet(panel); panel.close(); panel.contentView = nil } }, selectedRow: initialRow, selectedColumn: initialColumn))
        window.beginSheet(panel)
    }
    @discardableResult func applyMarkdownTable(_ table: MarkdownTable, replacing range: NSRange, expectedSource: String, inserting: Bool) -> Bool {
        guard isEditable, !hasMarkedText(), string == expectedSource, range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return false }
        let text = inserting ? "\n\n" + table.source + "\n\n" : table.source + (NSMaxRange(range) == (string as NSString).length ? "\n\n" : "")
        breakUndoCoalescing(); documentUndo.beginUndoGrouping(); insertText(text, replacementRange: range); documentUndo.endUndoGrouping(); breakUndoCoalescing()
        setSelectedRange(NSRange(location: min((string as NSString).length, range.location + text.utf16.count + 1), length: 0))
        renderedSource = nil; renderMarkdown(); return true
    }
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
        defer { styling = false; (enclosingScrollView as? MarkdownScrollView)?.scheduleSectionRefresh() }
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
        tableBlocks = MarkdownTables.blocks(in: string)
        renderedTables = []
        for block in tableBlocks {
            let firstLine = NSIntersectionRange(source.lineRange(for: NSRange(location: block.range.location, length: 0)), block.range)
            let layout = MarkdownTableLayout(table: block.table, width: max(80, (textContainer?.size.width ?? frame.width - textContainerInset.width * 2) - (liveEditing ? 32 : 0)), accent: taskAccent)
            let bodyStart = min(NSMaxRange(block.range), NSMaxRange(firstLine))
            let folded = NSRange(location: bodyStart, length: NSMaxRange(block.range) - bodyStart)
            renderedTables.append(.init(block: block, firstLine: firstLine, foldedRange: folded.length > 0 ? folded : nil, layout: layout))
            let hidden = NSMutableParagraphStyle(); hidden.minimumLineHeight = 0.01; hidden.maximumLineHeight = 0.01
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .paragraphStyle: hidden], range: block.range)
            let strut = NSMutableParagraphStyle(); strut.minimumLineHeight = layout.height + (liveEditing ? 44 : 8); strut.maximumLineHeight = strut.minimumLineHeight
            storage.addAttribute(.paragraphStyle, value: strut, range: firstLine)
        }
        codeRanges += tableBlocks.map(\.range)
        var mathRanges: [NSRange] = []
        func inCode(_ range: NSRange) -> Bool {
            codeRanges.contains { NSIntersectionRange($0, range).length > 0 } || mathRanges.contains {
                NSIntersectionRange($0, range).length > 0 && !(range.location <= $0.location && NSMaxRange(range) >= NSMaxRange($0))
            }
        }
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
        taskItems = []
        for match in matches("^([ \\t]*)[-+*][ \\t]+\\[([ xX])\\][ \\t]+(.+)$") where !inCode(match.range) {
            let content = match.range(at: 3)
            let marker = NSRange(location: match.range.location, length: content.location - match.range.location)
            guard !visible(marker) else { continue }
            let indentation = CGFloat(source.substring(with: match.range(at: 1)).replacingOccurrences(of: "\t", with: "    ").count) * 7
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4
            style.firstLineHeadIndent = indentation + 24; style.headIndent = indentation + 24
            storage.addAttribute(.paragraphStyle, value: style, range: match.range)
            hide(marker, context: marker, force: true)
            let checked = source.substring(with: match.range(at: 2)).lowercased() == "x"
            if checked { storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: content) }
            taskItems.append(TaskItem(marker: marker, state: match.range(at: 2), content: content, indent: indentation, checked: checked))
        }
        let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
        setAccessibilityCustomActions(taskItems.enumerated().map { index, task in
            let verb = english ? (task.checked ? "Uncheck" : "Check") : (task.checked ? "Desmarcar" : "Marcar")
            return NSAccessibilityCustomAction(name: verb + " " + source.substring(with: task.content)) { [weak self] in
                guard let self, self.taskItems.indices.contains(index) else { return false }
                self.toggleTask(at: index); return true
            }
        })
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
        inlineCode = []
        for match in matches("(?<!\\\\)`([^`\\n]+)`") where !inCode(match.range) {
            let body = match.range(at: 1)
            inlineCode.append(body)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: body)
            hide(NSRange(location: match.range.location, length: 1), context: match.range)
            hide(NSRange(location: NSMaxRange(match.range) - 1, length: 1), context: match.range)
            if !visible(match.range) {
                storage.addAttribute(.kern, value: 3, range: NSRange(location: match.range.location, length: 1))
                storage.addAttribute(.kern, value: 3, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            }
            codeRanges.append(match.range)
        }
        let mathSpans = MarkdownMath.spans(in: string, excluding: codeRanges)
        mathRanges = mathSpans.map(\.range)
        let formatSource = NSMutableString(string: string)
        for span in mathSpans {
            let masked = source.substring(with: span.range).utf16.map { $0 == 10 ? "\n" : " " }.joined()
            formatSource.replaceCharacters(in: span.range, with: masked)
        }
        func formatMatches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?.matches(in: formatSource as String, range: full) ?? []
        }
        let boldItalic = NSFontManager.shared.convert(.systemFont(ofSize: 16), toHaveTrait: [.boldFontMask, .italicFontMask])
        let formats: [(String, NSAttributedString.Key, Any, Int)] = [
            (#"(?<![\\*])\*\*\*([^*\n]+)\*\*\*(?!\*)"#, .font, boldItalic, 3),
            (#"(?<![\\*])\*\*([^*\n]+)\*\*(?!\*)"#, .font, NSFont.boldSystemFont(ofSize: 16), 2),
            (#"(?<![\\*])\*([^*\n]+)\*(?!\*)"#, .font, NSFontManager.shared.convert(.systemFont(ofSize: 16), toHaveTrait: .italicFontMask), 1),
            (#"(?<![\\\p{L}\p{N}_])___([^_\n]+)___(?![\p{L}\p{N}_])"#, .font, boldItalic, 3),
            (#"(?<![\\\p{L}\p{N}_])__([^_\n]+)__(?![\p{L}\p{N}_])"#, .font, NSFont.boldSystemFont(ofSize: 16), 2),
            (#"(?<![\\\p{L}\p{N}_])_([^_\n]+)_(?![\p{L}\p{N}_])"#, .font, NSFontManager.shared.convert(.systemFont(ofSize: 16), toHaveTrait: .italicFontMask), 1),
            ("(?<!\\\\)~~([^~\\n]+)~~", .strikethroughStyle, NSUnderlineStyle.single.rawValue, 2)
        ]
        for (pattern, key, value, count) in formats {
            for match in formatMatches(pattern) where !inCode(match.range) {
                let body = source.substring(with: match.range(at: 1))
                guard body.first?.isWhitespace == false, body.last?.isWhitespace == false else { continue }
                if key == .font, let requested = value as? NSFont {
                    let traits = NSFontManager.shared.traits(of: requested)
                    var fonts: [(NSRange, NSFont)] = []
                    storage.enumerateAttribute(.font, in: match.range(at: 1)) { value, range, _ in
                        fonts.append((range, NSFontManager.shared.convert(value as? NSFont ?? requested, toHaveTrait: traits)))
                    }
                    for (range, font) in fonts { storage.addAttribute(.font, value: font, range: range) }
                } else { storage.addAttribute(key, value: value, range: match.range(at: 1)) }
                hide(NSRange(location: match.range.location, length: count), context: match.range)
                hide(NSRange(location: NSMaxRange(match.range) - count, length: count), context: match.range)
            }
        }
        for span in InlineUnderline.spans(in: string, excluding: codeRanges) {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
            hide(span.opening, context: span.range)
            hide(span.closing, context: span.range)
        }
        for match in matches("(?<!\\\\)\\[([^]\\n]+)\\]\\(([^)\\n]+)\\)") where !inCode(match.range) {
            guard let url = URL(string: source.substring(with: match.range(at: 2))) else { continue }
            storage.addAttributes([.link: url, .foregroundColor: taskAccent], range: match.range(at: 1))
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
            if let link = url.url { storage.addAttributes([.link: link, .foregroundColor: taskAccent], range: label) }
            hide(NSRange(location: match.range.location, length: labelStart - match.range.location), context: match.range)
            hide(NSRange(location: NSMaxRange(label), length: 2), context: match.range)
        }
        renderedMath = []
        for span in mathSpans where !visible(span.range) {
            let font = storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont
            guard let render = MarkdownMathRenderer.render(span, source: string, fontSize: span.display ? 20 : (font?.pointSize ?? 16)) else { continue }
            renderedMath.append(render)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: span.range)
            if span.display {
                let style = NSMutableParagraphStyle(); style.alignment = .center
                style.paragraphSpacingBefore = 10; style.paragraphSpacing = 10
                style.minimumLineHeight = render.size.height + 16
                storage.addAttribute(.paragraphStyle, value: style, range: source.lineRange(for: span.range))
            } else if render.size.height > (font?.ascender ?? 16) - (font?.descender ?? -4) {
                let style = (storage.attribute(.paragraphStyle, at: span.range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.minimumLineHeight = max(style.minimumLineHeight, render.size.height + 6)
                storage.addAttribute(.paragraphStyle, value: style, range: source.lineRange(for: span.range))
            }
        }
        renderedImages = MarkdownImageRenderer.render(source: string, directory: imageDirectory, root: imageRoot, width: textContainer?.containerSize.width ?? 680).filter { !inCode($0.range) }
        for image in renderedImages {
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: image.range)
            let style = NSMutableParagraphStyle(); style.minimumLineHeight = image.size.height + 16; style.paragraphSpacing = 8
            storage.addAttribute(.paragraphStyle, value: style, range: image.range)
        }
        (layoutManager as? FoldingLayoutManager)?.images = Dictionary(uniqueKeysWithValues: renderedImages.map { ($0.range.location, $0) })
        let previousImageViews = imageViews
        var retainedImageViews = Set<ObjectIdentifier>()
        imageViews = renderedImages.map { render in
            let view = previousImageViews.first { !retainedImageViews.contains(ObjectIdentifier($0)) && $0.matches(render, editable: isEditable) } ?? MarkdownImageView()
            retainedImageViews.insert(ObjectIdentifier(view))
            view.editable = isEditable; view.maximumWidth = max(48, (textContainer?.containerSize.width ?? 680) - 16)
            view.configure(render); view.selected = selectedImageLocation == render.range.location
            view.onSelect = { [weak self] in self?.selectImage(at: render.range.location) }
            view.onChange = { [weak self] width, crop in self?.changeImage(at: render.range.location, width: width, crop: crop) }
            view.onDelete = { [weak self] in self?.selectedImageLocation = render.range.location; self?.removeSelectedImage() }
            view.onCopy = { [weak self] in self?.selectedImageLocation = render.range.location; self?.copySelectedImage() }
            if view.superview == nil { addSubview(view) }; return view
        }
        previousImageViews.filter { !retainedImageViews.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        (layoutManager as? FoldingLayoutManager)?.math = Dictionary(uniqueKeysWithValues: renderedMath.map { ($0.span.range.location, $0) })
        storage.endEditing()
        documentUndo.enableUndoRegistration()
        (layoutManager as? FoldingLayoutManager)?.foldedRanges = blocks.compactMap {
            collapsedBlocks.contains($0.id) ? foldedRange(for: $0) : nil
        } + renderedTables.compactMap(\.foldedRange) + renderedMath.map(\.foldedRange) + renderedImages.map(\.foldedRange)
        // Selection callbacks can restyle text during an AppKit character edit.
        // In that path, font changes outside the edited paragraph can retain
        // glyph IDs from the previous font. Regenerate them after styling.
        layoutManager?.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        syncVisualTableControls()
    }
    func updateImageSelection() {
        for (render, view) in zip(renderedImages, imageViews) { view.selected = selectedImageLocation == render.range.location }
    }
    private func positionImageViews() {
        guard let layoutManager, let textContainer else { return }
        for (render, view) in zip(renderedImages, imageViews) {
            if view.isResizing { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: render.range.location, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            view.frame = NSRect(x: textContainerOrigin.x + rect.minX, y: textContainerOrigin.y + rect.minY, width: render.size.width, height: render.size.height)
        }
    }

}
