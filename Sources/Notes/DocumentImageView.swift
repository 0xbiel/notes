import AppKit

/// A visual document object; the original asset is never rewritten by sizing or cropping.
@MainActor final class MarkdownImageView: NSView {
    override var isFlipped: Bool { true }
    let imageView = NSImageView()
    private let overlay = ImageSelectionOverlay()
    private let toolbar = NSVisualEffectView()
    private var render: RenderedMarkdownImage?
    private var cropMode = false
    private var cropSelection = NSRect(x: 0, y: 0, width: 1, height: 1)
    private var dragStart: NSPoint?
    private var originalSize = NSSize.zero
    private var resizing = false
    private var movingCrop = false
    private var initialCrop = NSRect.zero
    private var toolbarWidth: CGFloat = 148
    var isResizing: Bool { resizing }
    var selected = false { didSet { toolbar.isHidden = !selected; overlay.needsDisplay = true } }
    var editable = false
    var maximumWidth: CGFloat = 680
    var onSelect: (() -> Void)?
    var onChange: ((CGFloat?, NSRect) -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    private var english: Bool { UserDefaults.standard.string(forKey: "notes.language") == "en" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently; imageView.animates = true
        addSubview(imageView); overlay.owner = self; addSubview(overlay)
        toolbar.material = .popover; toolbar.blendingMode = .withinWindow; toolbar.state = .active
        toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 8; addSubview(toolbar)
        toolbar.isHidden = true
        setAccessibilityRole(.image); setAccessibilityLabel(english ? "Document image" : "Imagen del documento")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func matches(_ render: RenderedMarkdownImage, editable: Bool) -> Bool {
        self.render?.url == render.url && self.render?.crop == render.crop && self.render?.size == render.size && self.editable == editable
    }
    func configure(_ render: RenderedMarkdownImage) {
        self.render = render; if imageView.image !== render.image { imageView.image = render.image }; cropSelection = render.crop
        setAccessibilityIdentifier("document.image.\(render.range.location)")
        makeToolbar(); needsLayout = true
    }
    override func layout() {
        super.layout()
        overlay.frame = bounds
        if let render {
            if cropMode { imageView.frame = cropCanvas }
            else {
                let crop = render.crop
                imageView.frame = NSRect(x: -bounds.width * crop.minX / crop.width, y: -bounds.height * crop.minY / crop.height,
                                         width: bounds.width / crop.width, height: bounds.height / crop.height)
            }
        }
        toolbar.frame = NSRect(x: 8, y: 8, width: toolbarWidth, height: 32)
    }
    private var cropCanvas: NSRect {
        guard let render else { return bounds }
        let size = render.image.size
        let scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        return NSRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
    }
    private func makeToolbar() {
        toolbar.subviews.forEach { $0.removeFromSuperview() }
        let compact = (render?.size.width ?? bounds.width) < (cropMode ? 92 : 164)
        toolbarWidth = compact ? 32 : cropMode ? 76 : 148
        if compact {
            let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: english ? "Image options" : "Opciones de imagen")!, target: self, action: #selector(showImageMenu))
            button.isBordered = false; button.frame = NSRect(x: 0, y: 2, width: 32, height: 28); button.setAccessibilityLabel(english ? "Image options" : "Opciones de imagen"); toolbar.addSubview(button); return
        }
        let controls: [(String, String, Selector)] = cropMode ? [
            ("checkmark", english ? "Apply crop" : "Aplicar recorte", #selector(applyCrop)),
            ("xmark", english ? "Cancel crop" : "Cancelar recorte", #selector(cancelCrop))
        ] : [
            ("crop", english ? "Crop image" : "Recortar imagen", #selector(startCrop)),
            ("arrow.uturn.backward", english ? "Reset size and crop" : "Restablecer tamaño y recorte", #selector(resetImage)),
            ("doc.on.doc", english ? "Copy image" : "Copiar imagen", #selector(copyImage)),
            ("trash", english ? "Remove image" : "Eliminar imagen", #selector(deleteImage))
        ]
        for (index, control) in controls.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: control.0, accessibilityDescription: control.1)!, target: self, action: control.2)
            button.isBordered = false; button.toolTip = control.1; button.setAccessibilityLabel(control.1)
            button.setAccessibilityIdentifier("document.image." + control.0)
            button.frame = NSRect(x: 4 + index * 36, y: 2, width: 32, height: 28)
            button.isEnabled = editable || control.0 == "doc.on.doc"
            toolbar.addSubview(button)
        }
    }
    @objc private func showImageMenu() { imageMenu().popUp(positioning: nil, at: NSPoint(x: 8, y: 40), in: self) }
    fileprivate func imageMenu() -> NSMenu {
        onSelect?(); selected = true
        let menu = NSMenu()
        let items: [(String, Selector, Bool)] = cropMode ? [
            (english ? "Apply crop" : "Aplicar recorte", #selector(applyCrop), editable),
            (english ? "Cancel crop" : "Cancelar recorte", #selector(cancelCrop), true)
        ] : [
            (english ? "Crop image" : "Recortar imagen", #selector(startCrop), editable),
            (english ? "Reset size and crop" : "Restablecer tamaño y recorte", #selector(resetImage), editable),
            (english ? "Copy image" : "Copiar imagen", #selector(copyImage), true),
            (english ? "Remove image" : "Eliminar imagen", #selector(deleteImage), editable)
        ]
        menu.autoenablesItems = false
        for (label, action, enabled) in items { let item = NSMenuItem(title: label, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item) }
        return menu
    }
    @objc private func startCrop() { guard editable else { return }; cropMode = true; makeToolbar(); needsLayout = true; overlay.needsDisplay = true }
    @objc private func cancelCrop() { cropMode = false; if let render { cropSelection = render.crop }; makeToolbar(); needsLayout = true; overlay.needsDisplay = true }
    @objc private func applyCrop() { guard editable, let render else { return }; onChange?(max(48, frame.width * cropSelection.width / render.crop.width), cropSelection) }
    @objc private func resetImage() { guard editable else { return }; onChange?(nil, NSRect(x: 0, y: 0, width: 1, height: 1)) }
    @objc private func deleteImage() { if editable { onDelete?() } }
    @objc private func copyImage() { onCopy?() }

    fileprivate func drawSelection() {
        if cropMode {
            let canvas = cropCanvas
            let rect = NSRect(x: canvas.minX + cropSelection.minX * canvas.width, y: canvas.minY + cropSelection.minY * canvas.height, width: cropSelection.width * canvas.width, height: cropSelection.height * canvas.height)
            let mask = NSBezierPath(rect: bounds); mask.appendRect(rect); mask.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill(); mask.fill()
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: rect); outline.lineWidth = 2; outline.stroke()
            for point in [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)] {
                NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
            for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                let line = NSBezierPath(); line.move(to: NSPoint(x: rect.minX + rect.width * fraction, y: rect.minY)); line.line(to: NSPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                line.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * fraction)); line.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * fraction)); line.lineWidth = 0.5; line.stroke()
            }
        } else if selected {
            NSColor.controlAccentColor.setStroke(); let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
            if editable {
                for point in [NSPoint(x: 4, y: 4), NSPoint(x: bounds.maxX - 4, y: 4), NSPoint(x: 4, y: bounds.maxY - 4), NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)] {
                    let box = NSBezierPath(rect: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)); NSColor.white.setFill(); box.fill(); box.stroke()
                }
            }
        }
    }
    fileprivate func beginDrag(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onSelect?(); selected = true
        dragStart = point; originalSize = frame.size
        resizing = editable && !cropMode && (point.x < 12 || point.x > bounds.maxX - 12) && (point.y < 12 || point.y > bounds.maxY - 12)
        if cropMode {
            let canvas = cropCanvas
            let rect = NSRect(x: canvas.minX + cropSelection.minX * canvas.width, y: canvas.minY + cropSelection.minY * canvas.height, width: cropSelection.width * canvas.width, height: cropSelection.height * canvas.height)
            let corners = [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)]
            if let corner = corners.firstIndex(where: { abs($0.x - point.x) < 12 && abs($0.y - point.y) < 12 }) { dragStart = corners[3 - corner]; movingCrop = false }
            else { dragStart = constrained(point); movingCrop = rect.contains(point) && cropSelection != NSRect(x: 0, y: 0, width: 1, height: 1) }
            initialCrop = cropSelection
        }
    }
    private func constrained(_ point: NSPoint) -> NSPoint {
        let canvas = cropCanvas
        return NSPoint(x: min(canvas.maxX, max(canvas.minX, point.x)), y: min(canvas.maxY, max(canvas.minY, point.y)))
    }
    fileprivate func continueDrag(_ event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if cropMode {
            let end = constrained(point), canvas = cropCanvas
            if movingCrop {
                cropSelection.origin.x = min(1 - initialCrop.width, max(0, initialCrop.minX + (end.x - start.x) / canvas.width))
                cropSelection.origin.y = min(1 - initialCrop.height, max(0, initialCrop.minY + (end.y - start.y) / canvas.height))
                overlay.needsDisplay = true; return
            }
            cropSelection = NSRect(x: (min(start.x, end.x) - canvas.minX) / canvas.width, y: (min(start.y, end.y) - canvas.minY) / canvas.height,
                                   width: max(0.02, abs(end.x - start.x) / canvas.width), height: max(0.02, abs(end.y - start.y) / canvas.height))
            cropSelection.size.width = min(cropSelection.width, 1 - cropSelection.minX); cropSelection.size.height = min(cropSelection.height, 1 - cropSelection.minY)
            overlay.needsDisplay = true
        } else if resizing {
            let direction: CGFloat = start.x < 12 ? -1 : 1
            let width = min(maximumWidth, max(48, originalSize.width + (point.x - start.x) * direction))
            frame.size = NSSize(width: width, height: width * originalSize.height / originalSize.width)
            needsLayout = true; overlay.needsDisplay = true
        }
    }
    fileprivate func endDrag() {
        dragStart = nil
        if resizing, let render { resizing = false; onChange?(frame.width, render.crop) }
    }
}
@MainActor private final class ImageSelectionOverlay: NSView {
    weak var owner: MarkdownImageView?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { owner?.drawSelection() }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.imageMenu() }
    override func mouseDown(with event: NSEvent) { owner?.beginDrag(event) }
    override func mouseDragged(with event: NSEvent) { owner?.continueDrag(event) }
    override func mouseUp(with event: NSEvent) { owner?.endDrag() }
}
