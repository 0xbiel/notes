import XCTest
import AppKit
import LectureCore
@testable import Notes

final class RefinementTests: XCTestCase {
    @MainActor func testSidebarSelectionSurvivesResizeAndRowReuse() throws {
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let scroll = NSScrollView(frame: root.bounds)
        let table = NSTableView(frame: root.bounds)
        let source = SidebarSelectionDataSource()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = source
        scroll.documentView = table
        root.addSubview(scroll)
        let bridge = NeutralSidebarSelection.SelectionBridge(frame: .zero)
        root.addSubview(bridge)
        bridge.connect()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let overlay = try XCTUnwrap(table.subviews.compactMap { $0 as? NeutralSidebarSelection.SelectionOverlay }.first)
        XCTAssertNil(overlay.hitTest(.zero))
        for width in [240.0, 380.0, 260.0] {
            table.setFrameSize(NSSize(width: width, height: 400))
            table.reloadData()
            bridge.connect()
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
            XCTAssertEqual(table.selectionHighlightStyle, .none)
            XCTAssertEqual(overlay.frame, table.bounds)
            let selection = overlay.selectionRect(forRow: 1)
            XCTAssertEqual(selection.minX, table.rect(ofRow: 1).minX + 8)
            XCTAssertEqual(selection.maxX, table.rect(ofRow: 1).maxX - 8)
            XCTAssertTrue(table.subviews.contains { $0 === overlay })
        }
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 2)
        bridge.disconnect()
        XCTAssertNil(overlay.superview)
    }

    func testLibrarySeparatesOriginalVideoFromExtractedAudioAndMicrophone() {
        var video = MediaJob(notebookID: "test", subject: "Test", note: "Test.md", sourceName: "Lecture.MP4")
        video.audioRelativePath = "extracted.wav"
        XCTAssertTrue(LibraryContentFilter.video.includes(video))
        XCTAssertFalse(LibraryContentFilter.audio.includes(video))
        let audio = MediaJob(notebookID: "test", subject: "Test", note: "Test.md", sourceName: "Lecture.m4a")
        XCTAssertTrue(LibraryContentFilter.audio.includes(audio))
        XCTAssertFalse(LibraryContentFilter.video.includes(audio))
        let microphone = MediaJob(notebookID: "test", subject: "Test", note: "Test.md", sourceName: "Micrófono", microphone: true)
        XCTAssertTrue(LibraryContentFilter.audio.includes(microphone))
        XCTAssertFalse(LibraryContentFilter.video.includes(microphone))
    }

    func testImportedMediaFiltersAndNotebookRecordingOwnership() {
        for path in ["Class.MP4", "nested/Clip.webm", "Lecture.mkv"] {
            XCTAssertTrue(LibraryContentFilter.video.includes(path: path))
            XCTAssertFalse(LibraryContentFilter.audio.includes(path: path))
            XCTAssertFalse(LibraryContentFilter.notes.includes(path: path))
        }
        for path in ["nested/Audio.M4A", "Lecture.opus", "Recording.wav"] {
            XCTAssertTrue(LibraryContentFilter.audio.includes(path: path))
            XCTAssertFalse(LibraryContentFilter.video.includes(path: path))
            XCTAssertFalse(LibraryContentFilter.notes.includes(path: path))
        }
        for path in ["Note.md", "Guide.pdf", "Handout.docx", "Picture.png"] {
            XCTAssertTrue(LibraryContentFilter.notes.includes(path: path))
        }
        var local = MediaJob(notebookID: "one", subject: "One", note: "One.md", sourceName: "Voice", microphone: true)
        local.unitTags = ["Automata"]
        let sibling = MediaJob(notebookID: "two", subject: "Two", note: "Two.md", sourceName: "Voice", microphone: true)
        XCTAssertEqual(LibraryContentFilter.audio.recordings([sibling, local], notebookID: "one", query: "automata").map(\.id), [local.id])
        XCTAssertTrue(LibraryContentFilter.video.recordings([local], notebookID: "one", query: "").isEmpty)
        XCTAssertTrue(LibraryContentFilter.audio.recordings([local], notebookID: "two", query: "").isEmpty)
    }

    @MainActor func testFormattingRoundTripUndoAndSelection() async throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let original = "# Acción\n\nniño 👩🏽‍💻 y café"
        view.string = original
        let selected = (original as NSString).range(of: "niño 👩🏽‍💻")
        view.setSelectedRange(selected)
        view.toggleMarkdownBold(nil)
        try await Task.sleep(for: .milliseconds(10)) // Separate native input events.
        XCTAssertEqual(view.string, "# Acción\n\n**niño 👩🏽‍💻** y café")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "niño 👩🏽‍💻")
        view.undo(nil)
        XCTAssertEqual(view.string, original)
        view.redo(nil)
        view.setSelectedRange(NSRange(location: selected.location + 2, length: selected.length))
        view.toggleMarkdownBold(nil)
        try await Task.sleep(for: .milliseconds(10)) // Separate native input events.
        XCTAssertEqual(view.string, original)
        view.toggleMarkdownItalic(nil)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(view.string, "# Acción\n\n*niño 👩🏽‍💻* y café")
        view.undo(nil)
        XCTAssertEqual(view.string, original)
        view.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        view.toggleMarkdownCode(nil)
        XCTAssertTrue(view.string.hasSuffix("``"))
        XCTAssertEqual(view.selectedRange().location, original.utf16.count + 1)
    }
    @MainActor func testSyntaxRevealIsLocalAndHeadingSizeIsPreserved() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: .zero)
        let source = "# Un **título**\n\n**uno** y *dos*"
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "uno"))
        view.renderMarkdown()
        let strong = (source as NSString).range(of: "**uno**").location
        let italic = (source as NSString).range(of: "*dos*").location
        XCTAssertGreaterThan((view.textStorage!.attribute(.font, at: strong, effectiveRange: nil) as! NSFont).pointSize, 1)
        XCTAssertLessThan((view.textStorage!.attribute(.font, at: italic, effectiveRange: nil) as! NSFont).pointSize, 1)
        let title = (source as NSString).range(of: "título").location
        XCTAssertEqual((view.textStorage!.attribute(.font, at: title, effectiveRange: nil) as! NSFont).pointSize, 32)
        for _ in 0..<50 { view.renderMarkdown() }
        XCTAssertEqual(view.string, source)
        view.setFrameSize(NSSize(width: 350, height: 600))
        XCTAssertEqual(view.textContainerInset.width, 22)
        view.setFrameSize(NSSize(width: 900, height: 600))
        XCTAssertEqual(view.textContainerInset.width, 40)
    }
    @MainActor func testFormattingDuringCompositionAndReadingDoesNothing() async throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: .zero)
        view.string = "acción"
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.isEditable = false
        view.toggleMarkdownBold(nil)
        try await Task.sleep(for: .milliseconds(10)) // Separate native input events.
        XCTAssertEqual(view.string, "acción")
        view.isEditable = true
        view.setMarkedText("accio\u{301}n", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: 0, length: 6))
        let marked = view.string
        view.toggleMarkdownItalic(nil)
        XCTAssertEqual(view.string, marked)
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText()
    }
    func testStatusDoesNotClaimTranscriptExistsOrQualityIsVerified() {
        var job = MediaJob(notebookID: "test", subject: "Inventado", note: "Test.md", sourceName: "Prueba.m4a")
        job.stage = .transcribed
        XCTAssertEqual(RecordingPresentation(job: job).title, "Sin transcripción")
        job.transcript = [.init(id: "one", start: 0, end: 1, text: "Texto inventado")]
        XCTAssertEqual(RecordingPresentation(job: job).title, "Transcripción disponible")
        job.asrQualityWarning = "Revisar repetición"
        XCTAssertEqual(RecordingPresentation(job: job).title, "Por revisar")
        job.stage = .interrupted
        XCTAssertEqual(RecordingPresentation(job: job).title, "Interrumpido")
        job.stage = .recording
        XCTAssertEqual(RecordingPresentation(job: job).title, "Grabando")
    }
}

@MainActor private final class SidebarSelectionDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 4 }
}
