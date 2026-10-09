import AppKit
import SwiftUI

/// Keeps AppKit's scrolling, dragging and auto-hide behavior, with quieter knob rendering.
final class SubtleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    private var hoverTracking: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        var knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let emphasized = hovered || hitPart == .knob
        let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : emphasized ? 0.48 : 0.25
        let color = (dark ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
        if bounds.height > bounds.width { knob = knob.insetBy(dx: emphasized ? 0.5 : 1.5, dy: 0) }
        else { knob = knob.insetBy(dx: 0, dy: emphasized ? 0.5 : 1.5) }
        color.setFill()
        NSBezierPath(roundedRect: knob, xRadius: min(knob.width, knob.height) / 2, yRadius: min(knob.width, knob.height) / 2).fill()
    }
}

struct AppScrollbarAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarStyleHost { ScrollbarStyleHost() }
    func updateNSView(_ view: ScrollbarStyleHost, context: Context) { view.scheduleRefresh() }
}

final class ScrollbarStyleHost: NSView {
    private var pending = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleRefresh), name: NSApplication.didUpdateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleRefresh() }
    @objc func scheduleRefresh() {
        guard window != nil, !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.pending = false
            for window in NSApp.windows where !(window is NSSavePanel) {
                if let root = window.contentView { self.style(root) }
            }
        }
    }
    private func style(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            let vertical = scroll.hasVerticalScroller, horizontal = scroll.hasHorizontalScroller
            if let old = scroll.verticalScroller, !(old is SubtleScroller) { scroll.verticalScroller = replacement(for: old) }
            if let old = scroll.horizontalScroller, !(old is SubtleScroller) { scroll.horizontalScroller = replacement(for: old) }
            if scroll.hasVerticalScroller != vertical { scroll.hasVerticalScroller = vertical }
            if scroll.hasHorizontalScroller != horizontal { scroll.hasHorizontalScroller = horizontal }
        }
        for child in view.subviews { style(child) }
    }
    private func replacement(for old: NSScroller) -> SubtleScroller {
        let scroller = SubtleScroller(frame: old.frame)
        scroller.controlSize = old.controlSize
        scroller.scrollerStyle = old.scrollerStyle
        scroller.knobStyle = old.knobStyle
        scroller.target = old.target; scroller.action = old.action
        scroller.doubleValue = old.doubleValue; scroller.knobProportion = old.knobProportion
        scroller.isEnabled = old.isEnabled
        scroller.isHidden = old.isHidden
        return scroller
    }
}
