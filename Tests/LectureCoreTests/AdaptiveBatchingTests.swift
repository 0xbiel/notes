import XCTest
@testable import LectureCore

final class AdaptiveBatchingTests: XCTestCase {
    private func span(_ i: Int, seconds: Double = 10, text: String? = nil) -> MediaTranscriptSegment {
        .init(id: "s\(i)", start: Double(i) * seconds, end: Double(i + 1) * seconds,
              text: text ?? "Una explicación sustantiva que conserva el contexto de la clase.")
    }

    func testFiveMinuteCadenceAndIncrementalDelivery() {
        let speech = (0..<65).map { span($0) }
        XCTAssertTrue(AIOutbox.groups(Array(speech.prefix(29)), flush: false).isEmpty)
        let ready = AIOutbox.groups(speech, flush: false)
        XCTAssertEqual(ready.map(\.count), [30, 30])
        let tail = Array(speech.dropFirst(ready.flatMap { $0 }.count))
        XCTAssertTrue(AIOutbox.groups(tail, flush: false).isEmpty)
        XCTAssertEqual(AIOutbox.groups(tail, flush: true).flatMap { $0 }, tail)
    }

    func testSentenceGraceAndSparseSpeechDeadline() {
        let unfinished = (0..<33).map { span($0, text: "Una explicación sustantiva que continúa todavía sin terminar la frase") }
        XCTAssertTrue(AIOutbox.groups(Array(unfinished.prefix(32)), flush: false).isEmpty)
        XCTAssertEqual(AIOutbox.groups(unfinished, flush: false).count, 1)
        let sparse = (0..<15).map { span($0, seconds: 30, text: "Pausa.") }
        XCTAssertTrue(AIOutbox.groups(Array(sparse.prefix(14)), flush: false).isEmpty)
        XCTAssertEqual(AIOutbox.groups(sparse, flush: false).count, 1)
    }

    func testDenseAndFragmentedSpeechStayBoundedWithoutLosingSegments() {
        let dense = (0..<20).map { span($0, text: String(repeating: "contenido ", count: 350)) }
        let fragmented = (0..<300).map { span($0, seconds: 0.2, text: "palabra") }
        for source in [dense, fragmented] {
            let groups = AIOutbox.groups(source, flush: true)
            XCTAssertEqual(groups.flatMap { $0 }, source)
            XCTAssertTrue(groups.allSatisfy { $0.count <= AIOutbox.maximumBatchSegments })
            XCTAssertTrue(groups.allSatisfy { $0.map(\.text).joined().count <= AIOutbox.maximumBatchCharacters })
            XCTAssertGreaterThan(groups.count, 1)
        }
    }

    func testRealTranscriptBatchSizesWhenSupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTES_BATCHING_JOB"] else { throw XCTSkip("Optional existing local transcription checkpoint") }
        let job = try JSONDecoder().decode(MediaJob.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let groups = AIOutbox.groups(job.transcript, flush: true)
        XCTAssertEqual(groups.flatMap { $0 }.map(\.id), job.transcript.sorted { $0.start < $1.start }.map(\.id))
        XCTAssertTrue(groups.allSatisfy { $0.count <= AIOutbox.maximumBatchSegments && $0.map(\.text).joined().count <= AIOutbox.maximumBatchCharacters })
        print("REAL_BATCH_SIZES " + groups.map { "\(Int(($0.last?.end ?? 0) - ($0.first?.start ?? 0)))s/\($0.count) spans/\($0.map(\.text).joined().count) chars" }.joined(separator: ", "))
    }
}
