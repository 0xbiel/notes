import XCTest
@testable import LectureCore

private struct SequenceGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

final class NotebookPracticeTestTests: XCTestCase {
    private func workspace() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotesPractice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }
    private func question(_ id: String, options: Int = 4, correct: Int = 1) -> NotebookPracticeTest.Question {
        let choices = (0..<options).map { NotebookPracticeTest.Option(id: "\(id)-o\($0)", text: "Choice \($0)", explanation: "Because \($0)") }
        return .init(id: id, prompt: "Prompt \(id)", options: choices, correctOptionID: choices[correct].id, explanation: "Explained \(id)")
    }
    private func test(_ count: Int = 3) -> NotebookPracticeTest {
        .init(title: "Sample", instructions: "Pick one.", questions: (0..<count).map { question("q\($0)") })
    }

    func testValidationAcceptsBoundsAndRejectsEveryViolation() throws {
        try test(1).validate()
        try test(100).validate()
        XCTAssertThrowsError(try test(0).validate())
        XCTAssertThrowsError(try test(101).validate())
        var bad = test(); bad.title = "  "; XCTAssertThrowsError(try bad.validate())
        bad = test(); bad.instructions = ""; XCTAssertThrowsError(try bad.validate())
        bad = test(); bad.questions[1].id = "q0"
        XCTAssertThrowsError(try bad.validate()) { XCTAssertEqual($0 as? NotebookPracticeTestError, .duplicateQuestionID("q0")) }
        bad = test(); bad.questions[0].options[1].id = bad.questions[0].options[0].id
        XCTAssertThrowsError(try bad.validate())
        bad = test(); bad.questions[0].options = [bad.questions[0].options[1]]
        XCTAssertThrowsError(try bad.validate()) { XCTAssertEqual($0 as? NotebookPracticeTestError, .optionCount(question: "q0", count: 1)) }
        bad = test(); bad.questions[0] = question("q0", options: 9)
        XCTAssertThrowsError(try bad.validate())
        try NotebookPracticeTest(title: "T", instructions: "I", questions: [question("a", options: 8)]).validate()
        bad = test(); bad.questions[0].correctOptionID = "missing"
        XCTAssertThrowsError(try bad.validate()) { XCTAssertEqual($0 as? NotebookPracticeTestError, .invalidCorrectOption(question: "q0")) }
        bad = test(); bad.questions[0].options[0].explanation = " "; XCTAssertThrowsError(try bad.validate())
        bad = test(); bad.questions[0].explanation = ""; XCTAssertThrowsError(try bad.validate())
        bad = test(); bad.questions[0].prompt = String(repeating: "x", count: 4_001); XCTAssertThrowsError(try bad.validate())
        bad = test(); bad.questions[0].id = " q0"; XCTAssertThrowsError(try bad.validate())
    }

    func testDecodeRoundTripsAndRejectsMalformedOrOversizedData() throws {
        let original = test()
        XCTAssertEqual(try NotebookPracticeTest.decode(original.encoded()), original)
        let encoded = try original.encoded()
        XCTAssertEqual(encoded, try original.encoded())
        XCTAssertThrowsError(try NotebookPracticeTest.decode(Data("{}".utf8))) {
            guard case .unreadable = $0 as? NotebookPracticeTestError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try NotebookPracticeTest.decode(Data(count: NotebookPracticeTest.maximumBytes + 1)))
        var invalid = original; invalid.questions = []
        XCTAssertThrowsError(try invalid.encoded())
        XCTAssertTrue(NotebookPracticeTest.isPracticeTest("Course/Unit.quiz.json"))
        XCTAssertFalse(NotebookPracticeTest.isPracticeTest("Course/Unit.json"))
        XCTAssertEqual(NotebookPracticeTestError.questionCount(0).message(language: "en").contains("1 to 100"), true)
        XCTAssertTrue(NotebookPracticeTestError.questionCount(0).message(language: "es").contains("de 1 a 100"))
    }

    func testOptionalReferenceImagesRoundTripAndRejectUnsafeOrExcessiveMetadata() throws {
        var illustrated = test()
        let image = NotebookPracticeTest.ReferenceImage(path: "figures/pipeline.png", alt: "Stages A through D", caption: "Identify the bottleneck.")
        illustrated.questions[0].images = [image]
        XCTAssertEqual(try NotebookPracticeTest.decode(illustrated.encoded()), illustrated)
        XCTAssertNil(try NotebookPracticeTest.decode(test().encoded()).questions[0].images)
        for path in ["/tmp/figure.png", "https://example.com/figure.png", "figure\n.png", "C:\\figure.png"] {
            var invalid = illustrated
            invalid.questions[0].images = [.init(path: path, alt: "Figure")]
            XCTAssertThrowsError(try invalid.encoded())
        }
        var invalid = illustrated
        invalid.questions[0].images = [.init(path: "figure.png", alt: "")]
        XCTAssertThrowsError(try invalid.encoded())
        invalid.questions[0].images = Array(repeating: image, count: 5)
        XCTAssertThrowsError(try invalid.encoded())
        invalid = test(7)
        for index in invalid.questions.indices { invalid.questions[index].images = Array(repeating: image, count: 4) }
        XCTAssertThrowsError(try invalid.encoded())
    }

    func testReferenceImageResolutionStaysInsideNotebookIncludingSymlinks() throws {
        let workspace = try workspace()
        try workspace.createAsset("figures/image.png", data: Data([1, 2, 3]))
        let image = NotebookPracticeTest.ReferenceImage(path: "figures/image.png", alt: "Figure")
        XCTAssertEqual(try NotebookPracticeTest.referenceImageURL(image, directory: workspace.courseRoot, root: workspace.courseRoot), try workspace.fileURL("figures/image.png"))
        for path in ["../original/image.png", "/tmp/image.png", "https://example.com/image.png", "missing.png"] {
            XCTAssertThrowsError(try NotebookPracticeTest.referenceImageURL(.init(path: path, alt: "Figure"), directory: workspace.courseRoot, root: workspace.courseRoot))
        }
        let escaped = workspace.root.appendingPathComponent("outside.png")
        try Data([1]).write(to: escaped)
        let link = try workspace.fileURL("escaped.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: escaped)
        XCTAssertThrowsError(try NotebookPracticeTest.referenceImageURL(.init(path: "escaped.png", alt: "Figure"), directory: workspace.courseRoot, root: workspace.courseRoot))
    }

    func testShuffleKeepsEveryOptionAndNeverRepeatsPreviousOrderForAnyChoiceCount() {
        var generator = SequenceGenerator(state: 7)
        let questions = (2...8).map { question("c\($0)", options: $0, correct: 0) }
        let quiz = NotebookPracticeTest(title: "T", instructions: "I", questions: questions)
        var previous: [String: [String]] = [:]
        for _ in 0..<60 {
            let orders = quiz.shuffledOrders(previous: previous, using: &generator)
            for question in questions {
                let order = orders[question.id]!
                XCTAssertEqual(Set(order), Set(question.options.map(\.id)))
                XCTAssertEqual(order.count, question.options.count)
                XCTAssertNotEqual(order, previous[question.id] ?? question.options.map(\.id))
            }
            previous = orders
        }
    }

    func testStableOptionIDsGradeRegardlessOfDisplayedOrder() throws {
        let quiz = test(2)
        var generator = SequenceGenerator(state: 1)
        var history = NotebookPracticeHistory(path: "a.quiz.json", digest: "d")
        history.startAttempt(for: quiz, using: &generator)
        let displayed = quiz.orderedOptions(of: quiz.questions[0], order: history.latest?.optionOrder["q0"]).map(\.id)
        XCTAssertNotEqual(displayed, quiz.questions[0].options.map(\.id))
        try history.select("q0-o1", for: "q0", in: quiz)
        try history.select("q1-o0", for: "q1", in: quiz)
        let result = try history.submit(test: quiz)
        XCTAssertEqual(result.correct, 1); XCTAssertEqual(result.total, 2); XCTAssertEqual(result.percent, 50)
        XCTAssertEqual(result.item("q0")?.isCorrect, true); XCTAssertEqual(result.item("q1")?.isCorrect, false)
        XCTAssertEqual(history.latest?.correct, 1); XCTAssertTrue(history.latest?.isSubmitted == true)
    }

    func testSubmitRequiresEveryAnswerAndRejectsUnknownChoicesAndLateEdits() throws {
        let quiz = test(2)
        var generator = SequenceGenerator(state: 3)
        var history = NotebookPracticeHistory(path: "a.quiz.json", digest: "d")
        XCTAssertThrowsError(try history.submit(test: quiz)) { XCTAssertEqual($0 as? NotebookPracticeTestError, .noAttempt) }
        history.startAttempt(for: quiz, using: &generator)
        try history.select("q0-o0", for: "q0", in: quiz)
        XCTAssertThrowsError(try history.submit(test: quiz)) { XCTAssertEqual($0 as? NotebookPracticeTestError, .incomplete(missing: 1)) }
        XCTAssertFalse(history.latest?.isSubmitted ?? true)
        XCTAssertThrowsError(try history.select("nope", for: "q1", in: quiz))
        XCTAssertThrowsError(try history.select("q1-o0", for: "nope", in: quiz))
        try history.select("q1-o0", for: "q1", in: quiz)
        try history.submit(test: quiz)
        XCTAssertThrowsError(try history.select("q1-o1", for: "q1", in: quiz)) { XCTAssertEqual($0 as? NotebookPracticeTestError, .alreadySubmitted) }
        XCTAssertThrowsError(try history.submit(test: quiz))
    }

    func testRetakeKeepsHistoryAndReshufflesAwayFromPreviousAttempt() throws {
        let quiz = test(5)
        var generator = SequenceGenerator(state: 11)
        var history = NotebookPracticeHistory(path: "a.quiz.json", digest: "d")
        history.startAttempt(for: quiz, using: &generator)
        for question in quiz.questions { try history.select(question.correctOptionID, for: question.id, in: quiz) }
        try history.submit(test: quiz)
        let first = try XCTUnwrap(history.latest)
        history.startAttempt(for: quiz, using: &generator)
        XCTAssertEqual(history.attempts.count, 2)
        XCTAssertEqual(history.submittedAttempts.map(\.correct), [5])
        let second = try XCTUnwrap(history.latest)
        XCTAssertTrue(second.answers.isEmpty); XCTAssertFalse(second.isSubmitted); XCTAssertNotEqual(first.id, second.id)
        for question in quiz.questions { XCTAssertNotEqual(first.optionOrder[question.id], second.optionOrder[question.id]) }
        history.startAttempt(for: quiz, using: &generator)
        XCTAssertEqual(history.attempts.count, 2, "restarting replaces an unfinished attempt")
        for _ in 0..<(NotebookPracticeHistory.attemptLimit + 5) {
            var copy = history
            copy.attempts[copy.attempts.count - 1].submittedAt = Date(); copy.attempts[copy.attempts.count - 1].correct = 0
            history = copy; history.startAttempt(for: quiz, using: &generator)
        }
        XCTAssertEqual(history.attempts.count, NotebookPracticeHistory.attemptLimit)
    }

    func testIncompleteAndSubmittedAttemptsSurviveReopenWithoutStoringTheAnswerKey() throws {
        let workspace = try workspace(), quiz = test(2)
        let data = try quiz.encoded()
        try workspace.createAsset("Unit.quiz.json", data: data)
        let loaded = try NotebookPracticeTest.load(workspace: workspace, path: "Unit.quiz.json")
        XCTAssertEqual(loaded.test, quiz); XCTAssertEqual(loaded.digest, NotebookPracticeTest.digest(of: data))
        let store = NotebookPracticeStore(workspace: workspace, path: "Unit.quiz.json", digest: loaded.digest)
        XCTAssertTrue(store.load(for: quiz).attempts.isEmpty)
        var generator = SequenceGenerator(state: 5)
        var history = NotebookPracticeHistory(path: "Unit.quiz.json", digest: loaded.digest)
        history.startAttempt(for: quiz, using: &generator)
        try history.select("q0-o3", for: "q0", in: quiz)
        try store.save(history)
        let reopened = store.load(for: quiz)
        XCTAssertEqual(reopened, history)
        XCTAssertEqual(reopened.latest?.answers, ["q0": "q0-o3"])
        XCTAssertNil(reopened.latest?.correct)
        let stored = try String(decoding: workspace.readStorage(store.storagePath), as: UTF8.self)
        XCTAssertFalse(stored.contains("correctOptionID")); XCTAssertFalse(stored.contains("Because")); XCTAssertFalse(stored.contains("Choice"))
        try history.select("q1-o1", for: "q1", in: quiz)
        try history.submit(test: quiz)
        try store.save(history)
        XCTAssertEqual(store.load(for: quiz).latest?.correct, 1)
        XCTAssertTrue(store.load(for: quiz).latest?.isSubmitted == true)
    }

    func testAttemptsAreIsolatedByFileIdentityAndContentDigestAndCorruptStorageIsIgnored() throws {
        let workspace = try workspace(), quiz = test(2)
        var edited = quiz; edited.questions[0].prompt = "Changed"
        let first = NotebookPracticeStore(workspace: workspace, path: "A.quiz.json", digest: NotebookPracticeTest.digest(of: try quiz.encoded()))
        let sameFileEdited = NotebookPracticeStore(workspace: workspace, path: "A.quiz.json", digest: NotebookPracticeTest.digest(of: try edited.encoded()))
        let otherFile = NotebookPracticeStore(workspace: workspace, path: "B.quiz.json", digest: first.digest)
        XCTAssertEqual(Set([first.storagePath, sameFileEdited.storagePath, otherFile.storagePath]).count, 3)
        var generator = SequenceGenerator(state: 9)
        var history = NotebookPracticeHistory(path: first.path, digest: first.digest)
        history.startAttempt(for: quiz, using: &generator)
        try first.save(history)
        XCTAssertEqual(first.load(for: quiz).attempts.count, 1)
        XCTAssertTrue(sameFileEdited.load(for: edited).attempts.isEmpty)
        XCTAssertTrue(otherFile.load(for: quiz).attempts.isEmpty)
        try workspace.writeStorage(otherFile.storagePath, data: try JSONEncoder().encode(history))
        XCTAssertTrue(otherFile.load(for: quiz).attempts.isEmpty, "a copied history for another identity is rejected")
        try workspace.writeStorage(first.storagePath, data: Data("not json".utf8))
        XCTAssertTrue(first.load(for: quiz).attempts.isEmpty)
    }

    func testStoredAttemptsThatNoLongerMatchTheTestAreSanitized() throws {
        let quiz = test(2)
        var attempt = NotebookPracticeAttempt(optionOrder: ["q0": ["x", "y"], "q1": quiz.questions[1].options.map(\.id)], answers: ["q0": "gone", "q1": "q1-o2", "zz": "q1-o0"], total: 2)
        var history = NotebookPracticeHistory(path: "a", digest: "d", attempts: [attempt]).sanitized(for: quiz)
        XCTAssertEqual(history.latest?.answers, ["q1": "q1-o2"])
        XCTAssertNil(history.latest?.optionOrder["q0"])
        attempt.total = 7
        history = NotebookPracticeHistory(path: "a", digest: "d", attempts: [attempt]).sanitized(for: quiz)
        XCTAssertTrue(history.attempts.isEmpty)
        let fabricated = NotebookPracticeAttempt(submittedAt: Date(), optionOrder: [:], answers: [:], correct: 2, total: 2)
        XCTAssertTrue(NotebookPracticeHistory(path: "a", digest: "d", attempts: [fabricated]).sanitized(for: quiz).attempts.isEmpty)
    }

    func testLoadRejectsUnsafeNonQuizAndInvalidFiles() throws {
        let workspace = try workspace()
        try workspace.createAsset("Bad.quiz.json", data: Data("[]".utf8))
        XCTAssertThrowsError(try NotebookPracticeTest.load(workspace: workspace, path: "Bad.quiz.json"))
        XCTAssertThrowsError(try NotebookPracticeTest.load(workspace: workspace, path: "Bad.json"))
        XCTAssertThrowsError(try NotebookPracticeTest.load(workspace: workspace, path: "../Bad.quiz.json"))
        XCTAssertThrowsError(try NotebookPracticeTest.load(workspace: workspace, path: "Missing.quiz.json"))
    }
}
