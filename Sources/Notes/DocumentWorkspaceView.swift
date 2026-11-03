import SwiftUI
import LectureCore

struct DocumentWorkspaceView: View {
    @ObservedObject var model: Workbench
    var leadingInset: CGFloat = 0
    @State private var resizing: [String: Double] = [:]
    @State private var composerHeight: CGFloat = 130
    @State private var quizFooterHeights: [String: CGFloat] = [:]
    @StateObject private var composerRegion = DocumentComposerRegion()

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let frames = DocumentPaneFrames(root: model.documentWorkspace.root, bounds: CGRect(origin: .zero, size: geometry.size), resizing: resizing)
                let expanded = model.documentWorkspace.expandedID
                let footerInset = bottomFooterInset(frames: frames, height: geometry.size.height)
                ZStack(alignment: .topLeading) {
                    ForEach(model.documentWorkspace.documents) { document in
                        let visible = frames.panes[document.id] != nil && (expanded == nil || expanded == document.id)
                        let frame = expanded == document.id ? CGRect(origin: .zero, size: geometry.size) : frames.panes[document.id] ?? CGRect(origin: .zero, size: geometry.size)
                        let bottomPane = expanded == document.id || frame.maxY >= geometry.size.height - 1
                        let bottomInset = model.showsDocumentComposer && bottomPane
                            ? composerHeight + (NotebookPracticeTest.isPracticeTest(document.path) ? 0 : footerInset) : 0
                        DocumentPaneView(model: model, document: document, visible: visible, bottomInset: bottomInset,
                                         leadingInset: frame.minX == 0 && frame.minY == 0 ? leadingInset : 0, composerRegion: composerRegion,
                                         onFooterHeight: { quizFooterHeights[document.id] = $0 })
                            .frame(width: max(0, frame.width), height: max(0, frame.height))
                            .offset(x: frame.minX, y: frame.minY)
                            .opacity(visible ? 1 : 0)
                            .allowsHitTesting(visible)
                            .accessibilityHidden(!visible)
                    }
                    if expanded == nil {
                        ForEach(frames.dividers) { divider in
                            DocumentSplitDivider(axis: divider.axis)
                                .frame(width: divider.frame.width, height: divider.frame.height)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("document-panes"))
                                    .onChanged { value in
                                        let length = divider.axis == .horizontal ? divider.container.width : divider.container.height
                                        let position = divider.axis == .horizontal ? value.location.x - divider.container.minX : value.location.y - divider.container.minY
                                        resizing[divider.id] = min(0.85, max(0.15, position / max(1, length)))
                                    }
                                    .onEnded { _ in
                                        if let fraction = resizing[divider.id] {
                                            model.documentWorkspace.root = model.documentWorkspace.root?.resizing(divider.id, fraction: fraction)
                                        }
                                        resizing[divider.id] = nil
                                    })
                                .accessibilityLabel(Text(DocumentWorkspaceText.value("Resize split", "Redimensionar paneles")))
                                .accessibilityAdjustableAction { direction in
                                    let delta = direction == .increment ? 0.05 : -0.05
                                    model.documentWorkspace.root = model.documentWorkspace.root?.resizing(divider.id, fraction: divider.fraction + delta)
                                }
                                .offset(x: divider.frame.minX, y: divider.frame.minY)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: "document-panes")
                .overlay(alignment: .bottom) {
                    if model.showsDocumentComposer, let assistant = model.assistant {
                        NotebookComposer(model: model, assistant: assistant).frame(maxWidth: 740)
                            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                            .background(DocumentComposerHitRegion(region: composerRegion))
                            .padding(.bottom, footerInset)
                    }
                }
            }
        }
        .accessibilityIdentifier("workspace.documents")
        .background(DocumentPaneCloseShortcut(model: model))
    }

    private func bottomFooterInset(frames: DocumentPaneFrames, height: CGFloat) -> CGFloat {
        model.documentWorkspace.documents.compactMap { document -> CGFloat? in
            guard NotebookPracticeTest.isPracticeTest(document.path), let frame = frames.panes[document.id] else { return nil }
            if let expanded = model.documentWorkspace.expandedID {
                return expanded == document.id ? quizFooterHeights[document.id] ?? 64 : nil
            }
            return frame.maxY >= height - 1 ? quizFooterHeights[document.id] ?? 64 : nil
        }.max() ?? 0
    }
}

/// Flat frames keep each native editor/PDF view mounted while resizing, swapping or expanding.
struct DocumentPaneFrames {
    struct Divider: Identifiable {
        let id: String
        let axis: DocumentSplitAxis
        let fraction: Double
        let frame: CGRect
        let container: CGRect
    }
    var panes: [String: CGRect] = [:]
    var dividers: [Divider] = []

    init(root: DocumentPaneLayout?, bounds: CGRect, resizing: [String: Double] = [:]) {
        if let root { place(root, in: bounds, resizing: resizing) }
    }

    private mutating func place(_ node: DocumentPaneLayout, in bounds: CGRect, resizing: [String: Double]) {
        switch node {
        case .pane(let id): panes[id] = bounds
        case .split(let id, let axis, let fraction, let first, let second):
            let fraction = resizing[id] ?? fraction
            let length = axis == .horizontal ? bounds.width : bounds.height
            let gap = min(8, max(0, length))
            let size = max(0, length - gap) * fraction
            var a = bounds, b = bounds, handle = bounds
            if axis == .horizontal {
                a.size.width = size
                handle.origin.x += size; handle.size.width = gap
                b.origin.x += size + gap; b.size.width = max(0, length - size - gap)
            } else {
                a.size.height = size
                handle.origin.y += size; handle.size.height = gap
                b.origin.y += size + gap; b.size.height = max(0, length - size - gap)
            }
            dividers.append(.init(id: id, axis: axis, fraction: fraction, frame: handle, container: bounds))
            place(first, in: a, resizing: resizing); place(second, in: b, resizing: resizing)
        }
    }
}

private struct DocumentSplitDivider: View {
    let axis: DocumentSplitAxis
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.primary.opacity(hovering ? 0.4 : 0.18))
            .frame(width: axis == .horizontal ? 2 : 32, height: axis == .horizontal ? 32 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { inside in
                hovering = inside
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
    }
}

private struct DocumentPaneView: View {
    @ObservedObject var model: Workbench
    let document: WorkspaceDocument
    let visible: Bool
    let bottomInset: CGFloat
    let leadingInset: CGFloat
    let composerRegion: DocumentComposerRegion
    let onFooterHeight: (CGFloat) -> Void
    private var split: Bool { model.documentWorkspace.visibleIDs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTitleBar(model: model, leadingInset: leadingInset, document: document)
            WorkspaceDocumentContent(model: model, document: document, bottomInset: bottomInset, onFooterHeight: onFooterHeight)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: split ? 14 : 0))
            .overlay {
                if split {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.separator.opacity(0.25), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if split {
                    DocumentPaneHandle(model: model, document: document).padding(.top, 1)
                }
            }
            .overlay {
                if let target = model.documentDropPreview, target.paneID == document.id {
                    DocumentPaneDropHighlight(edge: target.edge)
                }
            }
            .background(DocumentPaneDropSurface(model: model, documentID: document.id, enabled: visible))
            .background(DocumentPaneFocusObserver(excluding: composerRegion) {
                if visible, !model.showPreferences, !model.showOnboarding { model.selectWorkspaceTab(document.id) }
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(URL(fileURLWithPath: document.path).lastPathComponent)
            .accessibilityIdentifier("workspace.pane.\(document.id)")
    }
}

private struct WorkspaceDocumentContent: View {
    @ObservedObject var model: Workbench
    let document: WorkspaceDocument
    let bottomInset: CGFloat
    let onFooterHeight: (CGFloat) -> Void
    private var path: String { document.path }
    private var notebook: Notebook { model.projects?.owner(of: path) ?? model.currentNotebook }

    var body: some View {
        Group {
            if path.hasSuffix(".md") {
                LiveMarkdownEditor(documentID: path, text: model.drafts[path] ?? "", editing: document.mode == "edit",
                    heading: model.documentWorkspace.focusedID == document.id ? model.previewHeading : nil, bottomInset: bottomInset,
                    imageDirectory: model.workspace?.courseRoot.appendingPathComponent(path).deletingLastPathComponent(),
                    imageRoot: model.workspace?.courseRoot.appendingPathComponent(notebook.rootPrefix),
                    importImage: { data, ext in
                        model.selectWorkspaceTab(document.id)
                        return try model.importDocumentImage(data, fileExtension: ext, note: path)
                    },
                    onChange: { model.changeDraft($0, for: path) },
                    onLink: { model.selectWorkspaceTab(document.id); _ = model.openWikilink($0) },
                    onTaskToggle: { _ in if document.mode == "preview" { model.saveDraft(named: path) } })
            } else if let workspace = model.workspace {
                if LaTeXDocument.isSource(path), let controller = try? model.latexController(path) {
                    LaTeXEditor(controller: controller, bottomInset: bottomInset)
                } else {
                    NotebookFilePreview(workspace: workspace, path: path, bottomInset: bottomInset,
                        imageRoot: workspace.courseRoot.appendingPathComponent(notebook.rootPrefix), notebookColor: notebook.color,
                        onFooterHeight: onFooterHeight, gradeAnswers: { test, answers in
                            guard let assistant = model.assistant, let ai = model.ai else { throw MediaError.invalid("AI grading is unavailable.") }
                            let configuration = ai.providerSettings.selected
                            let directory = try workspace.fileURL(path).deletingLastPathComponent()
                            let root = workspace.courseRoot.appendingPathComponent(notebook.rootPrefix)
                            let images = try test.questions.filter(\.isWritten).flatMap { question in
                                try (question.images ?? []).map { image in
                                    let url = try NotebookPracticeTest.referenceImageURL(image, directory: directory, root: root)
                                    return NotebookInputImage(name: question.id + ": " + image.alt, data: try Data(contentsOf: url))
                                }
                            }
                            let grades = try await assistant.transport.gradePracticeTest(test, answers: answers, images: images,
                                notebook: notebook, configuration: configuration,
                                language: UserDefaults.standard.string(forKey: "notes.language") ?? "es")
                            return (grades, configuration.model)
                        })
                }
            }
        }.id(path)
    }
}

/// Observe the mouse before native PDFKit/TextKit controls consume it; never intercept input.
struct DocumentPaneFocusObserver: NSViewRepresentable {
    let excluding: DocumentComposerRegion
    let focus: () -> Void
    func makeNSView(context: Context) -> FocusView { FocusView(excluding: excluding, focus: focus) }
    func updateNSView(_ view: FocusView, context: Context) { view.focus = focus; view.excluding = excluding }

    final class FocusView: NSView {
        var focus: () -> Void
        var excluding: DocumentComposerRegion
        nonisolated(unsafe) private var monitor: Any?
        init(excluding: DocumentComposerRegion, focus: @escaping () -> Void) { self.focus = focus; self.excluding = excluding; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseEvent(event)
                }
                return event
            }
        }
        func handleMouseEvent(_ event: NSEvent) {
            guard event.window === window, window?.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
                  visibleRect.intersection(bounds).contains(convert(event.locationInWindow, from: nil)), !excluding.contains(event) else { return }
            focus()
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// The shared composer can cross pane boundaries without changing the active document when clicked.
@MainActor final class DocumentComposerRegion: ObservableObject {
    weak var view: NSView?
    func contains(_ event: NSEvent) -> Bool {
        guard let view, view.window === event.window else { return false }
        return view.visibleRect.intersection(view.bounds).contains(view.convert(event.locationInWindow, from: nil))
    }
}

private struct DocumentComposerHitRegion: NSViewRepresentable {
    let region: DocumentComposerRegion
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); region.view = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) { region.view = view }
}

enum DocumentWorkspaceText {
    static func value(_ en: String, _ es: String) -> String {
        UserDefaults.standard.string(forKey: "notes.language") == "en" ? en : es
    }
}
