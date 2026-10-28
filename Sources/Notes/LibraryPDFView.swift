import SwiftUI
import PDFKit

struct LibraryPDFView: View {
    @StateObject private var controller: LibraryPDFController
    @AppStorage("notes.language") private var language = "es"
    init(url: URL) { _controller = StateObject(wrappedValue: LibraryPDFController(url: url)) }
    private func text(_ en: String, _ es: String) -> String { language == "en" ? en : es }
    var body: some View {
        if controller.pageCount == 0 {
            ContentUnavailableView(text("Unable to open PDF", "No se puede abrir el PDF"), systemImage: "doc.richtext")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) { zoomControls }
                    }
                    Divider().frame(height: 18)
                    pageControls.fixedSize()
                }.buttonStyle(.plain).font(.caption).padding(.horizontal, 12).padding(.vertical, 9)
                Divider().opacity(0.4)
                LibraryPDFCanvas(controller: controller)
            }
        }
    }

    private var pageControls: some View {
        HStack(spacing: 10) {
            Button { controller.go(to: controller.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(controller.page <= 1).accessibilityLabel(text("Previous page", "Página anterior"))
                .help(text("Previous page (←)", "Página anterior (←)")).accessibilityIdentifier("pdf.previousPage")
            TextField(text("Page", "Página"), text: $controller.pageText)
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 36)
                .onSubmit { controller.commitPage() }.accessibilityIdentifier("pdf.page")
            Text("/ \(controller.pageCount)").foregroundStyle(.secondary)
            Button { controller.go(to: controller.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(controller.page >= controller.pageCount).accessibilityLabel(text("Next page", "Página siguiente"))
                .help(text("Next page (→)", "Página siguiente (→)")).accessibilityIdentifier("pdf.nextPage")
        }
    }

    @ViewBuilder private var zoomControls: some View {
        Button { controller.zoom(by: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
            .accessibilityLabel(text("Zoom out", "Alejar"))
        TextField(text("Zoom percentage", "Porcentaje de zoom"), text: $controller.zoomText)
            .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 48)
            .onSubmit { controller.commitZoom() }.accessibilityIdentifier("pdf.zoom")
        Text("%")
        Button { controller.zoom(by: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
            .accessibilityLabel(text("Zoom in", "Acercar"))
        Menu {
            ForEach([25, 50, 75, 100, 125, 150, 200, 400], id: \.self) { percent in
                Button("\(percent)%") { controller.setPercentage(Double(percent)) }
            }
        } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(text("Zoom presets", "Opciones de zoom"))
        Button(text("Fit width", "Ajustar al ancho")) { controller.setFit(.width) }
            .foregroundStyle(controller.fit == .width ? .primary : .secondary).accessibilityIdentifier("pdf.fitWidth")
        Button(text("Fit height", "Ajustar al alto")) { controller.setFit(.height) }
            .foregroundStyle(controller.fit == .height ? .primary : .secondary).accessibilityIdentifier("pdf.fitHeight")
        Toggle(isOn: Binding(get: { controller.twoPages }, set: { controller.setTwoPages($0) })) {
            Label(text("Two pages", "Dos páginas"), systemImage: "book.pages")
        }.toggleStyle(.button).modifier(NotebookToggleAccent()).accessibilityIdentifier("pdf.twoPages")
    }

}

@MainActor final class LibraryPDFController: NSObject, ObservableObject {
    enum Fit { case width, height, custom }
    let document: PDFDocument?
    @Published private(set) var pageCount: Int
    @Published private(set) var page = 1
    @Published var pageText = "1"
    @Published var zoomText = "100"
    @Published private(set) var twoPages = false
    @Published private(set) var fit = Fit.width
    private(set) weak var view: PDFView?
    private var adjustingScale = false
    init(url: URL) {
        document = PDFDocument(url: url); pageCount = document?.pageCount ?? 0
        super.init()
    }
    func attach(_ view: PDFView) {
        NotificationCenter.default.removeObserver(self)
        self.view = view
        view.document = document; view.autoScales = false
        view.minScaleFactor = 0.01; view.maxScaleFactor = 64
        view.displayMode = .singlePageContinuous; view.displaysAsBook = false
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
        applyFit()
    }
    func commitZoom() {
        guard let percentage = Double(zoomText.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), percentage.isFinite, percentage > 0 else {
            refreshZoom(); return
        }
        setPercentage(percentage)
    }
    func setPercentage(_ percentage: Double) {
        guard percentage.isFinite, percentage > 0 else { return }
        fit = .custom; setScale(percentage / 100)
    }
    func zoom(by factor: Double) { setPercentage((view?.scaleFactor ?? 1) * factor * 100) }
    func commitPage() { go(to: Int(pageText.trimmingCharacters(in: .whitespaces)) ?? page) }
    func go(to requested: Int) {
        guard pageCount > 0, let document, let view else { return }
        let destination = min(max(1, requested), pageCount)
        if let target = document.page(at: destination - 1) { view.go(to: target) }
        page = destination; pageText = String(destination); applyFit()
    }
    func setFit(_ fit: Fit) { self.fit = fit; applyFit() }
    func setTwoPages(_ enabled: Bool) {
        twoPages = enabled
        view?.displayMode = enabled ? .twoUpContinuous : .singlePageContinuous
        applyFit()
    }
    func applyFit() {
        guard fit != .custom, let view, view.bounds.width > 24, view.bounds.height > 24, let document, let current = view.currentPage ?? document.page(at: 0) else { return }
        var pages = [current]
        if twoPages {
            let index = document.index(for: current), first = index - index % 2
            pages = (first..<min(first + 2, pageCount)).compactMap { document.page(at: $0) }
        }
        let sizes = pages.map { page -> CGSize in
            let bounds = page.bounds(for: view.displayBox)
            return abs(page.rotation) % 180 == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        }
        let width = sizes.reduce(0) { $0 + $1.width } + (sizes.count > 1 ? 12 : 0)
        let height = sizes.map(\.height).max() ?? 0
        guard width > 0, height > 0 else { return }
        setScale(fit == .width ? (view.bounds.width - 24) / width : (view.bounds.height - 24) / height)
    }
    private func setScale(_ scale: Double) {
        guard let view else { return }
        adjustingScale = true
        let bounded = min(max(view.minScaleFactor, scale), view.maxScaleFactor)
        if abs(view.scaleFactor - bounded) > 0.00001 { view.scaleFactor = bounded }
        refreshZoom(); adjustingScale = false
    }
    private func refreshZoom() {
        let percentage = Double(view?.scaleFactor ?? 1) * 100
        zoomText = percentage.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
    }
    @objc private func scaleChanged(_ notification: Notification) {
        if !adjustingScale { fit = .custom }
        refreshZoom()
    }
    @objc private func pageChanged(_ notification: Notification) {
        guard let current = view?.currentPage, let document else { return }
        page = document.index(for: current) + 1; pageText = String(page)
        applyFit()
    }
}

private struct LibraryPDFCanvas: NSViewRepresentable {
    let controller: LibraryPDFController
    func makeNSView(context: Context) -> LibraryPDFNativeView {
        let view = LibraryPDFNativeView(); view.backgroundColor = .clear
        view.controller = controller; controller.attach(view); return view
    }
    func updateNSView(_ view: LibraryPDFNativeView, context: Context) {}
    static func dismantleNSView(_ view: LibraryPDFNativeView, coordinator: ()) { view.stopKeyMonitor() }
}

final class LibraryPDFNativeView: PDFView {
    weak var controller: LibraryPDFController?
    private var fittedSize = CGSize.zero
    private var initializedViewport = false
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopKeyMonitor()
        guard window != nil else { return }
        // PDFKit's inner document view can consume arrows before PDFView sees
        // them, so intercept only events belonging to this focused preview.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleNavigationEvent(event) ?? false }
            return handled ? nil : event
        }
    }

    func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func handleNavigationEvent(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, event.window === window,
              let focused = window.firstResponder as? NSView, focused === self || focused.isDescendant(of: self) else { return false }
        if let editor = focused as? NSTextView, editor.isEditable { return false }
        return handlePageKey(event)
    }

    @discardableResult func handlePageKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let controller, controller.pageCount > 0 else { return false }
        switch event.keyCode {
        case 123: controller.go(to: controller.page - 1)
        case 124: controller.go(to: controller.page + 1)
        default: return false
        }
        return true
    }

    override func layout() {
        super.layout()
        if bounds.size != fittedSize {
            fittedSize = bounds.size; controller?.applyFit()
            if !initializedViewport, bounds.width > 24, bounds.height > 24 {
                initializedViewport = true
                controller?.go(to: 1)
            }
        }
    }
}
