import XCTest
import AppKit
import SwiftUI
import LectureCore
@testable import Notes

private struct SequenceGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

final class NotebookPracticeTestViewTests: XCTestCase {
    private func workspace() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotesPracticeUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }
    private func quiz(prompt: String = "What is $x^2$?") -> NotebookPracticeTest {
        let questions = (0..<3).map { index in
            NotebookPracticeTest.Question(id: "q\(index)", prompt: index == 0 ? prompt : "Prompt \(index)",
                options: (0..<4).map { .init(id: "q\(index)-o\($0)", text: "Choice \(index).\($0)", explanation: "Because \(index).\($0)") },
                correctOptionID: "q\(index)-o2", explanation: "Explained \(index)")
        }
        return .init(title: "Unit test", instructions: "Choose **one** answer.", questions: questions)
    }
    @MainActor private func controller(_ workspace: SafeWorkspace, seed: UInt64 = 1, path: String = "Unit.quiz.json") -> NotebookPracticeTestController {
        NotebookPracticeTestController(workspace: workspace, path: path, generator: SequenceGenerator(state: seed))
    }

    @MainActor func testUnfinishedAttemptExposesNoAnswerKeyAndRequiresEveryAnswer() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        XCTAssertEqual(model.totalCount, 3); XCTAssertEqual(model.answeredCount, 0)
        XCTAssertFalse(model.canSubmit); XCTAssertNil(model.result)
        XCTAssertTrue(model.displays.allSatisfy { $0.review == nil })
        let dump = String(describing: model.displays)
        XCTAssertFalse(dump.contains("Because")); XCTAssertFalse(dump.contains("Explained"))
        model.select("q0-o2", for: "q0"); model.select("q1-o0", for: "q1")
        XCTAssertEqual(model.remainingCount, 1); XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.submit()); XCTAssertFalse(model.isSubmitted)
        XCTAssertTrue(model.displays.allSatisfy { $0.review == nil })
        model.select("q2-o2", for: "q2")
        XCTAssertTrue(model.canSubmit)
    }

    @MainActor func testFlowAllowsBrowsingWithoutAnswersButRequiresAnswersToSubmit() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        XCTAssertEqual(model.visibleDisplays(layout: .flow).map(\.id), ["q0"])
        XCTAssertEqual(model.visibleDisplays(layout: .all).count, 3)
        XCTAssertTrue(model.canContinue)
        model.nextQuestion()
        XCTAssertEqual(model.questionIndex, 1)
        model.nextQuestion()
        XCTAssertEqual(model.questionIndex, 2)
        XCTAssertEqual(model.answeredCount, 0)
        XCTAssertFalse(model.submit())
        model.previousQuestion(); model.previousQuestion()
        XCTAssertEqual(model.questionIndex, 0)
        model.select("q0-o2", for: "q0")
        XCTAssertTrue(model.canContinue)
        model.nextQuestion()
        XCTAssertEqual(model.visibleDisplays(layout: .flow).map(\.id), ["q1"])
        XCTAssertTrue(model.canContinue)
        model.previousQuestion()
        XCTAssertEqual(model.currentDisplay?.selectedID, "q0-o2")
        model.nextQuestion()
        model.select("q1-o1", for: "q1"); model.nextQuestion()
        XCTAssertTrue(model.isLastQuestion); XCTAssertFalse(model.canContinue)
        model.nextQuestion()
        XCTAssertEqual(model.questionIndex, 2)
        XCTAssertFalse(model.canSubmit)
        model.select("q2-o2", for: "q2")
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(model.visibleDisplays(layout: .flow).allSatisfy { $0.review == nil })
        XCTAssertEqual(model.visibleDisplays(layout: .all).map(\.selectedID), ["q0-o2", "q1-o1", "q2-o2"])
    }

    @MainActor func testFlowResumesFirstUnansweredAndSwitchingDoesNotReshuffle() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        let order = model.attempt?.optionOrder
        model.select("q0-o2", for: "q0")
        model.select("q2-o1", for: "q2")
        model.resumeFlow()
        XCTAssertEqual(model.currentDisplay?.id, "q1")
        let reopened = controller(workspace)
        XCTAssertEqual(reopened.currentDisplay?.id, "q1")
        XCTAssertEqual(reopened.attempt?.optionOrder, order)
        XCTAssertEqual(reopened.visibleDisplays(layout: .all).map(\.selectedID), ["q0-o2", nil, "q2-o1"])
        reopened.select("q1-o0", for: "q1"); reopened.resumeFlow()
        XCTAssertTrue(reopened.isLastQuestion)
        XCTAssertEqual(reopened.attempt?.optionOrder, order)
    }

    @MainActor func testFlowReviewNavigatesAndRetakeRestartsAtFirstQuestion() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        for index in 0..<3 { model.select("q\(index)-o2", for: "q\(index)") }
        XCTAssertTrue(model.submit())
        model.resumeFlow()
        XCTAssertEqual(model.questionIndex, 0)
        XCTAssertNotNil(model.visibleDisplays(layout: .flow).first?.review)
        model.nextQuestion(); model.nextQuestion()
        XCTAssertTrue(model.isLastQuestion)
        model.previousQuestion()
        XCTAssertEqual(model.questionIndex, 1)
        model.retake()
        XCTAssertEqual(model.questionIndex, 0)
        XCTAssertNil(model.currentDisplay?.review)
        XCTAssertTrue(model.canContinue)
    }

    @MainActor func testQuestionIndexNavigationPreservesAnswersAndOptionOrder() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        let order = model.attempt?.optionOrder
        model.goToQuestion("q2")
        XCTAssertEqual(model.questionIndex, 2)
        model.goToQuestion("missing")
        XCTAssertEqual(model.questionIndex, 2)
        model.goToQuestion("q0")
        model.select("q0-o2", for: "q0")
        model.goToQuestion("q1")
        XCTAssertNil(model.currentDisplay?.selectedID)
        model.goToQuestion("q0")
        XCTAssertEqual(model.currentDisplay?.selectedID, "q0-o2")
        XCTAssertEqual(model.answeredCount, 1)
        XCTAssertEqual(model.attempt?.optionOrder, order)
        XCTAssertFalse(model.canSubmit)
    }

    func testQuestionScrollMetricsTrackCurrentVisibleAndProgress() {
        let metrics = NotebookPracticeScrollMetrics(questions: [
            "q0": CGRect(x: 0, y: -240, width: 400, height: 200),
            "q1": CGRect(x: 0, y: -20, width: 400, height: 200),
            "q2": CGRect(x: 0, y: 200, width: 400, height: 200)
        ], content: CGRect(x: 0, y: -250, width: 400, height: 1000))
        XCTAssertEqual(metrics.currentID(order: ["q0", "q1", "q2"]), "q1")
        XCTAssertEqual(metrics.visibleIDs(height: 300), ["q1", "q2"])
        XCTAssertEqual(metrics.visibleIDs(height: 0), [])
        XCTAssertEqual(metrics.progress(height: 500), 0.5)
        XCTAssertNil(NotebookPracticeScrollMetrics().currentID(order: ["q0"]))
        for (offset, expected) in [(20.0, 0.0), (-700.0, 1.0)] {
            let edge = NotebookPracticeScrollMetrics(content: CGRect(x: 0, y: offset, width: 400, height: 1000))
            XCTAssertEqual(edge.progress(height: 500), expected)
        }
        XCTAssertEqual(metrics.progress(height: 1200), 0)
    }

    @MainActor func testLongQuestionPickerSearchAndBoundedHeight() throws {
        let workspace = try workspace()
        var longTest = quiz()
        longTest.questions = (1...40).map { number in
            var question = quiz().questions[0]
            question.id = "question-\(number)"
            question.prompt = number == 40 ? "Find the bottleneck in $t_k$." : "Pipeline question \(number)"
            return question
        }
        try workspace.createAsset("Unit.quiz.json", data: longTest.encoded())
        let model = controller(workspace)
        let matching = NotebookPracticeQuestionNavigation.matching
        XCTAssertEqual(matching(model.displays, "").count, 40)
        XCTAssertEqual(matching(model.displays, " 40 ").map(\.number), [40])
        XCTAssertEqual(matching(model.displays, "BOTTLENECK").map(\.number), [40])
        XCTAssertTrue(matching(model.displays, "missing").isEmpty)
        XCTAssertEqual(NotebookPracticeQuestionNavigation.pickerHeight(count: 40), 340)
        XCTAssertEqual(NotebookPracticeQuestionNavigation.pickerHeight(count: 1), 64)
        XCTAssertEqual(NotebookPracticeQuestionNavigation.pickerHeight(count: 0), 64)
        model.goToQuestion("question-40")
        XCTAssertEqual(model.currentDisplay?.number, 40)
        XCTAssertEqual(model.answeredCount, 0)
        XCTAssertFalse(model.canSubmit)
    }

    @MainActor func testQuestionPickerPreviewLeavesInputToItsScrollableRow() {
        let preview = NotebookPracticePreviewTextView(frame: CGRect(x: 0, y: 0, width: 280, height: 30))
        XCTAssertNil(preview.hitTest(CGPoint(x: 100, y: 15)))
        let rich = MarkdownMathText.attributed("Preview $x^2$", fontSize: 12)
        XCTAssertFalse(rich.string.contains("$"))
        XCTAssertNotNil(rich.attribute(.attachment, at: rich.length - 1, effectiveRange: nil))
    }

    @MainActor func testReferenceFiguresAppearInBothLayoutsAndMissingImagesFailSafely() throws {
        _ = NSApplication.shared
        let workspace = try workspace()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try workspace.createAsset("figures/pipeline (1).png", data: data)
        let image = NotebookPracticeTest.ReferenceImage(path: "figures/pipeline (1).png", alt: "Four pipeline stages", caption: "Which stage is the bottleneck?")
        var illustrated = quiz()
        illustrated.questions[0].images = [image]
        try workspace.createAsset("Unit.quiz.json", data: illustrated.encoded())
        let model = controller(workspace)
        XCTAssertEqual(model.visibleDisplays(layout: .flow)[0].images, [image])
        XCTAssertEqual(model.visibleDisplays(layout: .all)[0].images, [image])
        XCTAssertNil(model.currentDisplay?.review)
        XCTAssertNotNil(NotebookPracticeReferenceImage.rendered(image, directory: workspace.courseRoot, root: workspace.courseRoot))
        XCTAssertNil(NotebookPracticeReferenceImage.rendered(.init(path: "../outside.png", alt: "Escape"), directory: workspace.courseRoot, root: workspace.courseRoot))
        XCTAssertNil(NotebookPracticeReferenceImage.rendered(.init(path: "missing.png", alt: "Missing"), directory: workspace.courseRoot, root: workspace.courseRoot))
    }

    @MainActor func testMixedTextAndMathUseConsistentFontAndFitAnOptionRow() throws {
        let source = "The slowest stage: $\\max{t_1,\\dots,t_k}$"
        XCTAssertEqual(NotebookChatMarkdown.blocks(source).count, 1)
        let attributed = MarkdownMathText.attributed(source, fontSize: 16)
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 16)
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        XCTAssertLessThan(manager.usedRect(for: container).height, 30)
        XCTAssertLessThan(manager.usedRect(for: container).width, 500)
    }

    @MainActor func testSubmitRevealsWrongChoiceAndCorrectAnswerExplanationsThenRetakeHidesThemAgain() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        model.select("q0-o2", for: "q0"); model.select("q1-o0", for: "q1"); model.select("q2-o2", for: "q2")
        XCTAssertTrue(model.submit())
        XCTAssertEqual(model.result?.correct, 2); XCTAssertEqual(model.result?.total, 3)
        let reviews = model.displays.map(\.review)
        XCTAssertEqual(reviews[0]?.isCorrect, true)
        XCTAssertEqual(reviews[1]?.isCorrect, false)
        XCTAssertEqual(reviews[1]?.selectedExplanation, "Because 1.0")
        XCTAssertEqual(reviews[1]?.correctExplanation, "Because 1.2")
        XCTAssertEqual(reviews[1]?.explanation, "Explained 1")
        model.select("q1-o1", for: "q1")
        XCTAssertEqual(model.displays[1].selectedID, "q1-o0", "a submitted attempt cannot be edited")
        let before = model.attempt?.optionOrder
        model.retake()
        XCTAssertFalse(model.isSubmitted); XCTAssertNil(model.result); XCTAssertEqual(model.answeredCount, 0)
        XCTAssertTrue(model.displays.allSatisfy { $0.review == nil })
        XCTAssertFalse(String(describing: model.displays).contains("Explained"))
        XCTAssertEqual(model.earlierAttempts.map(\.correct), [2])
        for id in ["q0", "q1", "q2"] { XCTAssertNotEqual(model.attempt?.optionOrder[id], before?[id]) }
    }

    @MainActor func testIncompleteAndSubmittedStateSurviveReopeningTheFile() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let first = controller(workspace)
        first.select("q0-o1", for: "q0")
        let order = first.attempt?.optionOrder
        let reopened = controller(workspace, seed: 99)
        XCTAssertEqual(reopened.attempt?.id, first.attempt?.id)
        XCTAssertEqual(reopened.attempt?.optionOrder, order)
        XCTAssertEqual(reopened.displays[0].selectedID, "q0-o1")
        XCTAssertEqual(reopened.displays.map { $0.options.map(\.id) }, first.displays.map { $0.options.map(\.id) })
        reopened.select("q1-o2", for: "q1"); reopened.select("q2-o2", for: "q2"); XCTAssertTrue(reopened.submit())
        let submitted = controller(workspace, seed: 5)
        XCTAssertTrue(submitted.isSubmitted); XCTAssertEqual(submitted.result?.correct, 2)
        XCTAssertNotNil(submitted.displays[0].review)
    }

    @MainActor func testEditedFileStartsAFreshIsolatedAttemptAndKeepsOldHistoryAside() throws {
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz().encoded())
        let model = controller(workspace)
        model.select("q0-o1", for: "q0")
        let original = model.attempt?.id
        try Data(quiz(prompt: "Changed prompt").encoded()).write(to: workspace.fileURL("Unit.quiz.json"))
        model.reload()
        XCTAssertEqual(model.displays[0].prompt, "Changed prompt")
        XCTAssertEqual(model.answeredCount, 0); XCTAssertNotEqual(model.attempt?.id, original)
        try quiz().encoded().write(to: workspace.fileURL("Unit.quiz.json"))
        model.reload()
        XCTAssertEqual(model.attempt?.id, original); XCTAssertEqual(model.displays[0].selectedID, "q0-o1")
    }

    @MainActor func testInvalidOrMissingFilesReportAnErrorInsteadOfAQuiz() throws {
        let workspace = try workspace()
        try workspace.createAsset("Bad.quiz.json", data: Data("{\"title\":\"x\"}".utf8))
        let bad = controller(workspace, path: "Bad.quiz.json")
        XCTAssertNil(bad.test); XCTAssertNotNil(bad.loadError); XCTAssertTrue(bad.displays.isEmpty); XCTAssertFalse(bad.canSubmit)
        XCTAssertFalse(bad.submit())
        let missing = controller(workspace, path: "Missing.quiz.json")
        XCTAssertNil(missing.test); XCTAssertNotNil(missing.loadError)
    }

    func testLabelsExistInEnglishAndSpanish() {
        let en = NotebookPracticeText(language: "en"), es = NotebookPracticeText(language: "es")
        XCTAssertEqual(en.submit, "Submit answers"); XCTAssertEqual(es.submit, "Enviar respuestas")
        XCTAssertEqual(en.scoreLine(2, 3), "2 of 3 correct"); XCTAssertEqual(es.scoreLine(2, 3), "2 de 3 correctas")
        XCTAssertEqual(en.retake, "Retake test"); XCTAssertEqual(es.retake, "Repetir test")
        XCTAssertEqual(en.flow, "One at a time"); XCTAssertEqual(es.allQuestions, "Todas las preguntas")
        XCTAssertEqual(en.next, "Continue"); XCTAssertEqual(es.back, "Anterior")
        XCTAssertEqual(en.position(2, of: 3), "Question 2 of 3")
        XCTAssertNotEqual(en.whyWrong, es.whyWrong); XCTAssertNotEqual(en.remaining(2), es.remaining(2))
        XCTAssertTrue(es.error(NotebookPracticeTestError.incomplete(missing: 2)).contains("Responde"))
        XCTAssertTrue(en.error(NotebookPracticeTestError.incomplete(missing: 2)).contains("Answer"))
    }

    @MainActor func testViewRendersFromJSONAndPreviewRoutesQuizFilesToIt() throws {
        _ = NSApplication.shared
        let workspace = try workspace()
        try workspace.createAsset("Unit.quiz.json", data: quiz(prompt: "Which statement is true?").encoded())
        let host = NSHostingView(rootView: NotebookPracticeTestView(workspace: workspace, path: "Unit.quiz.json").frame(width: 800, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 700); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        let preview = NSHostingView(rootView: NotebookFilePreview(workspace: workspace, path: "Unit.quiz.json").frame(width: 800, height: 700))
        preview.frame = host.frame; preview.layoutSubtreeIfNeeded()
        XCTAssertTrue(NotebookPracticeTest.isPracticeTest("Unit.quiz.json"))
    }

    @MainActor func testAllQuestionsOnlyMountsNearbyMathCards() async throws {
        _ = NSApplication.shared
        let workspace = try workspace()
        var longTest = quiz()
        longTest.questions = (1...40).map { number in
            var question = quiz().questions[0]
            question.id = "question-\(number)"
            question.prompt = "Lazy item \(number): what is $x^2$?"
            return question
        }
        try workspace.createAsset("Unit.quiz.json", data: longTest.encoded())
        let suite = "NotesPracticePerformance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: "notes.practiceTest.layout")
        let host = NSHostingView(rootView: NotebookPracticeTestView(workspace: workspace, path: "Unit.quiz.json")
            .defaultAppStorage(defaults).frame(width: 800, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func prompts(in view: NSView) -> [String] {
            let own = (view as? NSTextView).map { $0.string.hasPrefix("Lazy item") ? [$0.string] : [] } ?? []
            return own + view.subviews.flatMap { prompts(in: $0) }
        }
        let mounted = prompts(in: host)
        XCTAssertFalse(mounted.isEmpty)
        XCTAssertLessThan(mounted.count, 10, "Offscreen questions should not mount their rich text views.")
        XCTAssertFalse(mounted.contains { $0.hasPrefix("Lazy item 40:") })
    }
}
