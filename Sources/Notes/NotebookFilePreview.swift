import SwiftUI
import PDFKit
import Quartz
import LectureCore

struct NotebookFilePreview: View {
    let workspace: SafeWorkspace
    let path: String
    var bottomInset: CGFloat = 0
    var imageRoot: URL? = nil
    var onFooterHeight: ((CGFloat) -> Void)? = nil
    var gradeAnswers: NotebookPracticeGrader? = nil
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        if let url = try? workspace.fileURL(path) {
            Group {
                if NotebookPracticeTest.isPracticeTest(path) {
                    NotebookPracticeTestView(workspace: workspace, path: path, imageRoot: imageRoot, bottomInset: bottomInset, onFooterHeight: onFooterHeight, gradeAnswers: gradeAnswers)
                } else if url.pathExtension.lowercased() == "pdf" {
                    LibraryPDFView(url: url).accessibilityIdentifier("notebook.pdfPreview")
                } else {
                    LibraryQuickLookView(url: url).accessibilityIdentifier("notebook.filePreview")
                }
            }.id(path)
        } else { ContentUnavailableView(language == "en" ? "File unavailable" : "Archivo no disponible", systemImage: "doc") }
    }
}
struct LibraryQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false; view.previewItem = url as NSURL; return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
enum LibraryFileIcon {
    static func symbol(_ path: String) -> String {
        if NotebookPracticeTest.isPracticeTest(path) { return "checklist" }
        return switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "svg": "photo"
        case "mp3", "wav", "m4a", "aac", "flac": "waveform"
        case "mp4", "mov", "mkv", "webm": "film"
        case "zip", "gz", "tar": "doc.zipper"
        default: "doc.text"
        }
    }
}
