import XCTest
@testable import LectureCore

final class NotebookWrittenGradeTests: XCTestCase {
    private var test: NotebookPracticeTest {
        .init(title: "Mixed quiz", instructions: "Answer both questions", questions: [
            .init(id: "written", prompt: "Explain mitosis", options: [], correctOptionID: "", explanation: "Describe cell division and its phases.", images: [.init(path: "figure.png", alt: "Cell diagram")], answerType: "text"),
            .init(id: "choice", prompt: "Pick one", options: [.init(id: "yes", text: "Yes", explanation: "Correct"), .init(id: "no", text: "No", explanation: "Incorrect")], correctOptionID: "yes", explanation: "Yes is correct")
        ])
    }
    private var grade: NotebookWrittenGrade { .init(score: 6.5, feedback: "Good start", mistakes: "No factual errors", omissions: "Explain the phases and their roles") }

    func testMixedQuizRoundTripsAndUsesPartialCredit() throws {
        let quiz = try NotebookPracticeTest.decode(test.encoded())
        XCTAssertEqual(quiz, test)
        let answers = ["written": "Cells divide", "choice": "yes"]
        XCTAssertThrowsError(try quiz.grade(answers))
        let result = try quiz.grade(answers, writtenGrades: ["written": grade])
        XCTAssertEqual(result.score, 8.25)
        XCTAssertEqual(result.percent, 83)
        XCTAssertEqual(result.correct, 1)
        XCTAssertThrowsError(try quiz.grade(["written": " \n", "choice": "yes"], writtenGrades: ["written": grade]))
    }

    func testGradesRequireExactQuestionsValidScoresAndFeedback() throws {
        let json = """
        {"written":{"score":6.5,"feedback":"Good start","mistakes":"None","omissions":"Missing phases"}}
        """
        XCTAssertEqual(try NotebookWrittenGrade.decode(json, questionIDs: ["written"])["written"]?.score, 6.5)
        XCTAssertThrowsError(try NotebookWrittenGrade.decode(json, questionIDs: ["other"]))
        for score in [-1.0, 10.1, .infinity, .nan] {
            var invalid = grade; invalid.score = score
            XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = grade; invalid.omissions = " "
        XCTAssertThrowsError(try invalid.validate())
    }

    func testWrittenAttemptPersistsFeedbackAndRetakeStartsFresh() throws {
        var history = NotebookPracticeHistory(path: "a.quiz.json", digest: "digest")
        var generator = SystemRandomNumberGenerator()
        history.startAttempt(for: test, using: &generator)
        try history.select("Cells divide", for: "written", in: test)
        try history.select("yes", for: "choice", in: test)
        XCTAssertThrowsError(try history.submit(test: test))
        XCTAssertFalse(history.latest!.isSubmitted)
        try history.submit(test: test, writtenGrades: ["written": grade], gradingModel: "selected-model")
        let restored = try JSONDecoder().decode(NotebookPracticeHistory.self, from: JSONEncoder().encode(history)).sanitized(for: test)
        XCTAssertEqual(restored.latest?.writtenGrades?["written"], grade)
        XCTAssertEqual(restored.latest?.gradingModel, "selected-model")
        XCTAssertThrowsError(try history.select("changed", for: "written", in: test))
        history.startAttempt(for: test, using: &generator)
        XCTAssertTrue(history.latest!.answers.isEmpty)
        XCTAssertNil(history.latest!.writtenGrades)
    }
}
