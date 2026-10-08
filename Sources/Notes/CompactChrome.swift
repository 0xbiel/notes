import AppKit
import SwiftUI

/// Presentation state only: never owns the document, its selection or its undo manager.
@MainActor
final class CompactChrome: ObservableObject {
    @Published var compact = false
    @Published var pinned = false
    @Published private(set) var sidebarRevealed = false
    @Published private(set) var toolbarRevealed = false
    private var sidebarRequested = false
    private var sidebarDeadline: TimeInterval?
    private var toolbarDeadline: TimeInterval?
    var sidebarVisible: Bool { pinned || sidebarRevealed }
    var toolbarVisible: Bool { !compact || toolbarRevealed }

    func toggleCompact() {
        compact.toggle()
        toolbarRevealed = false
        toolbarDeadline = nil
    }
    func toggleSidebar() {
        let shouldOpen = !sidebarVisible
        sidebarRevealed = shouldOpen
        sidebarRequested = shouldOpen
        if !shouldOpen { pinned = false }
        sidebarDeadline = nil
    }
    func togglePin() {
        pinned.toggle()
        sidebarRevealed = true
        sidebarRequested = false
    }
    func revealToolbar() { toolbarRevealed = true; toolbarDeadline = nil }

    /// Deterministic clock makes edge crossing and cancellation independently testable.
    func update(now: TimeInterval, sidebarHit: Bool, toolbarHit: Bool, hold: Bool) {
        if sidebarHit { sidebarRevealed = true; sidebarDeadline = nil }
        if toolbarHit { toolbarRevealed = true; toolbarDeadline = nil }
        guard !hold else { sidebarDeadline = nil; toolbarDeadline = nil; return }
        if !sidebarHit && !pinned && !sidebarRequested && sidebarRevealed {
            if let deadline = sidebarDeadline, now >= deadline { sidebarRevealed = false; sidebarDeadline = nil }
            else if sidebarDeadline == nil { sidebarDeadline = now + 0.15 }
        }
        if !toolbarHit && toolbarRevealed {
            if let deadline = toolbarDeadline, now >= deadline { toolbarRevealed = false; toolbarDeadline = nil }
            else if toolbarDeadline == nil { toolbarDeadline = now + 1 }
        }
    }
    func dismissTransient() {
        sidebarRevealed = false; toolbarRevealed = false
        sidebarRequested = false
        sidebarDeadline = nil; toolbarDeadline = nil
    }
}

struct CompactWindowBridge: NSViewRepresentable {
    @ObservedObject var chrome: CompactChrome
    let modalPresented: Bool
    func makeNSView(context: Context) -> ChromeWindowView { ChromeWindowView(chrome: chrome) }
    func updateNSView(_ view: ChromeWindowView, context: Context) {
        view.modalPresented = modalPresented
        view.syncButtons()
    }
    static func dismantleNSView(_ view: ChromeWindowView, coordinator: ()) { view.detach() }
}

/// Background-only view. It never intercepts editor events or changes first responder.
@MainActor
final class ChromeWindowView: NSView {
    let chrome: CompactChrome
    var modalPresented = false
    private weak var attachedWindow: NSWindow?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var menuDepth = 0
    private var previousTitleVisibility: NSWindow.TitleVisibility = .visible
    private var previousTransparent = false
    private var previousFullSize = false
    private var previousToolbarVisible: Bool?
    private var buttonVisibility: [NSWindow.ButtonType: Bool] = [:]
    init(chrome: CompactChrome) { self.chrome = chrome; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== attachedWindow else { return }
        detach()
        guard let window else { return }
        attachedWindow = window
        previousTitleVisibility = window.titleVisibility
        previousTransparent = window.titlebarAppearsTransparent
        previousFullSize = window.styleMask.contains(.fullSizeContentView)
        previousToolbarVisible = window.toolbar?.isVisible
        for type in Self.buttonTypes { buttonVisibility[type] = window.standardWindowButton(type)?.isHidden ?? false }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar?.isVisible = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuDepth += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuDepth = max(0, self.menuDepth - 1) } }
        })
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        syncButtons()
    }
    static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    func syncButtons() {
        guard let window = attachedWindow else { return }
        for type in Self.buttonTypes { window.standardWindowButton(type)?.isHidden = !chrome.toolbarVisible }
    }
    func trackPointer() {
        guard let window = attachedWindow, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = bounds.contains(point)
        // Flipped coordinates are normalized here; the view may be hosted either way.
        let yFromTop = isFlipped ? point.y : bounds.height - point.y
        let sidebar = inside && point.x >= bounds.width - (chrome.sidebarVisible ? 304 : 12)
            && yFromTop > 64 && yFromTop < bounds.height - 80
        let toolbar = inside && yFromTop < (chrome.toolbarVisible ? 70 : 12)
        let field = window.firstResponder as? NSTextView
        let editingControl = field?.isFieldEditor == true
        chrome.update(now: ProcessInfo.processInfo.systemUptime,
                      sidebarHit: sidebar, toolbarHit: toolbar,
                      hold: menuDepth > 0 || modalPresented || editingControl || NSEvent.pressedMouseButtons != 0)
        syncButtons()
    }
    func detach() {
        timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); menuDepth = 0
        if let window = attachedWindow {
            window.titleVisibility = previousTitleVisibility
            window.titlebarAppearsTransparent = previousTransparent
            if !previousFullSize { window.styleMask.remove(.fullSizeContentView) }
            if let previousToolbarVisible { window.toolbar?.isVisible = previousToolbarVisible }
            for type in Self.buttonTypes { window.standardWindowButton(type)?.isHidden = buttonVisibility[type] ?? false }
        }
        attachedWindow = nil
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
        override func accessibilityLabel() -> String? { "Mover ventana" }
    }
}
