import AppKit
import SwiftUI

enum CompactLayout {
    static let sidebarWidth: CGFloat = 260
    static let horizontalInset: CGFloat = 8
    static let verticalInset = horizontalInset
    static let sidebarRadius: CGFloat = 12
    static let rowRadius: CGFloat = 6
}

/// Presentation state only: never owns the document, its selection or its undo manager.
@MainActor
final class CompactChrome: ObservableObject {
    @Published var compact = false
    @Published var pinned = false
    @Published private(set) var sidebarRevealed = false
    @Published private(set) var toolbarRevealed = false
    weak var windowButtons: WindowButtonsView?
    private var suppressRevealUntilExit = false
    private var sidebarDeadline: TimeInterval?
    private var toolbarDeadline: TimeInterval?
    var sidebarVisible: Bool { !compact || pinned || sidebarRevealed }
    var toolbarVisible: Bool { !compact || toolbarRevealed }

    func toggleCompact() {
        compact.toggle()
        pinned = false
        sidebarRevealed = false
        sidebarDeadline = nil
        suppressRevealUntilExit = compact
        toolbarRevealed = false
        toolbarDeadline = nil
    }
    func toggleSidebar() {
        if !compact { toggleCompact(); return }
        sidebarRevealed = !sidebarVisible
        if !sidebarRevealed { pinned = false; suppressRevealUntilExit = true }
        else { suppressRevealUntilExit = false }
        sidebarDeadline = nil
    }
    func togglePin() {
        pinned.toggle()
        sidebarRevealed = true
        suppressRevealUntilExit = false
    }
    func revealToolbar() { toolbarRevealed = true; toolbarDeadline = nil }

    /// Deterministic clock makes edge crossing and cancellation independently testable.
    func update(now: TimeInterval, sidebarHit: Bool, toolbarHit: Bool, hold: Bool) {
        if !sidebarHit { suppressRevealUntilExit = false }
        if sidebarHit && !suppressRevealUntilExit { sidebarRevealed = true; sidebarDeadline = nil }
        if toolbarHit { toolbarRevealed = true; toolbarDeadline = nil }
        guard !hold else { sidebarDeadline = nil; toolbarDeadline = nil; return }
        if !sidebarHit && !pinned && sidebarRevealed {
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
        suppressRevealUntilExit = false
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
    private var previousTabbingMode: NSWindow.TabbingMode = .automatic
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
        previousTabbingMode = window.tabbingMode
        previousFullSize = window.styleMask.contains(.fullSizeContentView)
        previousToolbarVisible = window.toolbar?.isVisible
        for type in Self.buttonTypes { buttonVisibility[type] = window.standardWindowButton(type)?.isHidden ?? false }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar?.isVisible = false
        window.tabbingMode = .disallowed
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
        // AppKit can reposition/reparent traffic lights on activation and resizing.
        // Reconcile their native views with the sidebar host after each such layout.
        chrome.windowButtons?.installButtons()
        for type in Self.buttonTypes { window.standardWindowButton(type)?.isHidden = !chrome.sidebarVisible }
    }
    func trackPointer() {
        guard let window = attachedWindow, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = bounds.contains(point)
        // Flipped coordinates are normalized here; the view may be hosted either way.
        let yFromTop = isFlipped ? point.y : bounds.height - point.y
        let sidebar = inside && point.x <= (chrome.sidebarVisible ? CompactLayout.sidebarWidth + 2 * CompactLayout.horizontalInset : 12)
        let toolbar = inside && yFromTop < (chrome.toolbarVisible ? 70 : 12)
        chrome.update(now: ProcessInfo.processInfo.systemUptime,
                      sidebarHit: sidebar, toolbarHit: toolbar,
                      hold: menuDepth > 0 || modalPresented || NSEvent.pressedMouseButtons != 0)
        syncButtons()
    }
    func detach() {
        timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); menuDepth = 0
        if let window = attachedWindow {
            window.titleVisibility = previousTitleVisibility
            window.titlebarAppearsTransparent = previousTransparent
            window.tabbingMode = previousTabbingMode
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

/// Hosts AppKit's actual window buttons in the sidebar, preserving native actions.
struct NativeWindowControls: NSViewRepresentable {
    let chrome: CompactChrome
    func makeNSView(context: Context) -> WindowButtonsView {
        let view = WindowButtonsView()
        chrome.windowButtons = view
        return view
    }
    func updateNSView(_ view: WindowButtonsView, context: Context) { view.installButtons() }
    static func dismantleNSView(_ view: WindowButtonsView, coordinator: ()) { view.restoreButtons() }
}

@MainActor
final class WindowButtonsView: NSView {
    private struct Original {
        let button: NSButton
        let parent: NSView
        let frame: NSRect
        let bounds: NSRect
    }
    private var originals: [Original] = []
    private var controlsHovered = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { restoreButtons() } else { installButtons() }
    }
    func installButtons() {
        guard let window else { return }
        if originals.isEmpty {
        for type in ChromeWindowView.buttonTypes {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            originals.append(Original(button: button, parent: parent, frame: button.frame, bounds: button.bounds))
            addSubview(button)
        }
        }
        for original in originals where original.button.superview !== self {
            addSubview(original.button)
        }
        positionButtons()
        updateMonochromeAppearance()
    }
    private func positionButtons() {
        for (index, original) in originals.enumerated() {
            let size = NSSize(width: original.frame.width * 1.15, height: original.frame.height * 1.15)
            original.button.frame = NSRect(x: CGFloat(index) * 24, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            original.button.bounds = original.bounds
        }
    }
    override func layout() {
        super.layout()
        positionButtons()
    }
    // Zen's mono-window-controls uses three theme-colored dots until hover,
    // then reveals the real macOS controls. Keep AppKit actions and accessibility.
    private func updateMonochromeAppearance() {
        guard let window else { return }
        let hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if hovered != controlsHovered { controlsHovered = hovered; needsDisplay = true }
        for original in originals {
            original.button.wantsLayer = true
            original.button.layer?.opacity = hovered ? 1 : 0
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !controlsHovered else { return }
        NSColor.labelColor.withAlphaComponent(window?.isKeyWindow == true ? 0.28 : 0.16).setFill()
        for original in originals {
            let center = original.button.frame
            NSBezierPath(ovalIn: NSRect(x: center.midX - 7, y: center.midY - 7, width: 14, height: 14)).fill()
        }
    }
    func restoreButtons() {
        for original in originals {
            original.button.layer?.opacity = 1
            original.parent.addSubview(original.button)
            original.button.frame = original.frame
            original.button.bounds = original.bounds
        }
        originals.removeAll()
    }
}

struct ChromeCommands: Commands {
    @FocusedObject private var chrome: CompactChrome?
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Mostrar u ocultar biblioteca") { chrome?.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(chrome == nil)
            Button("Alternar modo compacto") { chrome?.toggleCompact() }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                .disabled(chrome == nil)
            Button("Alternar modo compacto (⌥⌘C)") { chrome?.toggleCompact() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(chrome == nil)
        }
    }
}
