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
        // Custom sidebar controls replace AppKit's; keep the native ones hidden.
        for type in Self.buttonTypes { window.standardWindowButton(type)?.isHidden = true }
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

/// Window dragging for bars that host hover controls. The AppKit drag view underneath
/// makes SwiftUI hover tracking flicker, so newer systems use the native SwiftUI gesture.
struct WindowDragArea: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
        } else {
            content.background(WindowDragRegion())
        }
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

/// Sidebar window controls drawn from scratch (T3 Code style). AppKit's own traffic
/// lights stay hidden while the chrome is attached; these never reparent native views,
/// so geometry is fixed and hovering only changes colour and glyphs.
struct NativeWindowControls: NSViewRepresentable {
    let chrome: CompactChrome
    func makeNSView(context: Context) -> WindowButtonsView { WindowButtonsView() }
    func updateNSView(_ view: WindowButtonsView, context: Context) {}
}

@MainActor
final class WindowButtonsView: NSView {
    static let diameter: CGFloat = 14
    static let spacing: CGFloat = 23
    private(set) var buttons: [WindowControlButton] = []
    private(set) var groupHovered = false
    private var hoverArea: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        buttons = ChromeWindowView.buttonTypes.map { WindowControlButton(kind: $0) }
        buttons.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * Self.spacing, y: ((bounds.height - Self.diameter) / 2).rounded(),
                                  width: Self.diameter, height: Self.diameter)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.buttons.forEach { $0.needsDisplay = true } }
            })
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { updateHoverState(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHoverState(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHoverState(at: nil) }
    func updateHoverState(at point: NSPoint?) {
        let hovered = point.map { bounds.contains($0) } ?? false
        guard hovered != groupHovered else { return }
        groupHovered = hovered
        buttons.forEach { $0.needsDisplay = true }
    }
}

@MainActor
final class WindowControlButton: NSButton {
    let kind: NSWindow.ButtonType
    init(kind: NSWindow.ButtonType) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        target = self
        action = #selector(performWindowAction)
        let label: String = switch kind {
        case .closeButton: "Close"
        case .miniaturizeButton: "Minimize"
        default: "Full Screen"
        }
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    @objc private func performWindowAction() {
        guard let window else { return }
        switch kind {
        case .closeButton: window.performClose(nil)
        case .miniaturizeButton: window.performMiniaturize(nil)
        default:
            if NSEvent.modifierFlags.contains(.option) { window.performZoom(nil) } else { window.toggleFullScreen(nil) }
        }
    }
    private var fill: NSColor {
        switch kind {
        case .closeButton: NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1)
        case .miniaturizeButton: NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)
        default: NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let hovered = (superview as? WindowButtonsView)?.groupHovered ?? false
        if hovered, let image = NativeWindowButtonArtwork.image(kind, pressed: isHighlighted, appearance: effectiveAppearance) {
            image.draw(in: bounds)
            return
        }
        if hovered {
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return
        }
        // Flat, borderless dot while idle.
        NSColor.labelColor.withAlphaComponent(window?.isKeyWindow == true ? 0.26 : 0.15).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Snapshots of AppKit's real traffic-light artwork (Liquid Glass on current macOS),
/// rendered offscreen at high resolution so hovered controls look native while their
/// geometry stays ours.
@MainActor
enum NativeWindowButtonArtwork {
    private final class GroupHost: NSView {
        // Native buttons draw their glyphs only when their group reports hover.
        @objc(_mouseInGroup:) func mouseInGroup(_ button: NSButton) -> Bool { true }
    }
    private static var cache: [String: NSImage] = [:]
    static func image(_ kind: NSWindow.ButtonType, pressed: Bool, appearance: NSAppearance) -> NSImage? {
        let name = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        let key = "\(kind.rawValue)-\(pressed)-\(name.rawValue)"
        if let cached = cache[key] { return cached }
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        guard let button = NSWindow.standardWindowButton(kind, for: mask) else { return nil }
        let size = button.frame.size
        let host = GroupHost(frame: NSRect(origin: .zero, size: size))
        host.appearance = NSAppearance(named: name)
        button.setFrameOrigin(.zero)
        host.addSubview(button)
        button.isHighlighted = pressed
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        cache[key] = image
        return image
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
