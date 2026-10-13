import SwiftUI
import PDFKit
import LectureCore

struct NotebookAttachmentStrip: View {
    let attachments: [NotebookAttachment]
    let workspace: SafeWorkspace
    var remove: ((String) -> Void)? = nil
    @State private var preview: NotebookAttachment?
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        Button { preview = attachment } label: {
                            HStack(spacing: 8) {
                                if attachment.imageCount > 0,
                                   let data = try? workspace.readStorage(attachment.storagePrefix + "/0.png"), let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                                } else { Image(systemName: "doc.text").frame(width: 30) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(attachment.name).lineLimit(1).font(.caption.weight(.medium))
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: 170, alignment: .leading)
                            }
                        }.buttonStyle(.plain).accessibilityLabel((language == "en" ? "Preview " : "Ver ") + attachment.name)
                        if let remove {
                            Button { remove(attachment.id) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 24) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel((language == "en" ? "Remove " : "Quitar ") + attachment.name)
                        }
                    }.padding(8).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
            .sheet(item: $preview) { attachment in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(attachment.name).font(.headline); Spacer(); Button(language == "en" ? "Done" : "Listo") { preview = nil } }
                    if let data = try? workspace.readStorage(attachment.storagePrefix + "/original") {
                        if attachment.isPDF { AttachmentPDFPreview(data: data) }
                        else if attachment.isImage, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else { ScrollView { Text(attachment.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    } else { Text(language == "en" ? "Attachment unavailable." : "Archivo no disponible.") }
                }.padding(20).frame(minWidth: 500, idealWidth: 700, minHeight: 400, idealHeight: 600)
            }
    }
}
private struct AttachmentPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

/// Intercept image/file paste only while the composer owns keyboard focus.
/// A SwiftUI onPasteCommand can also replace Paste inside native open panels.
struct NotebookAttachmentPasteTarget: NSViewRepresentable {
    let receive: ([NSItemProvider]) -> Void
    func makeNSView(context: Context) -> PasteTarget { let view = PasteTarget(); view.receive = receive; return view }
    func updateNSView(_ view: PasteTarget, context: Context) { view.receive = receive }
    static func dismantleNSView(_ view: PasteTarget, coordinator: ()) { view.stop() }
    final class PasteTarget: NSView {
        var receive: (([NSItemProvider]) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        func handle(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown,
                  let window, window.isKeyWindow, window.attachedSheet == nil,
                  event.windowNumber == window.windowNumber,
                  let editor = window.firstResponder as? NSTextView,
                  editor.convert(editor.bounds, to: nil).intersects(convert(bounds, to: nil)) else { return false }
            let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
            if modifiers == .shift, event.keyCode == 36 || event.keyCode == 76 {
                guard editor.isEditable, !editor.hasMarkedText() else { return false }
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return true
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
            let clipboard = NSPasteboard.general
            if clipboard.types?.contains(.fileURL) == true,
               let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                receive?(urls.map { NSItemProvider(item: Data($0.absoluteString.utf8) as NSData, typeIdentifier: "public.file-url") }); return true
            }
            for type in [NSPasteboard.PasteboardType.png, .tiff] where clipboard.types?.contains(type) == true {
                if let data = clipboard.data(forType: type) {
                    let provider = NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
                    receive?([provider]); return true
                }
            }
            return false
        }
    }
}
