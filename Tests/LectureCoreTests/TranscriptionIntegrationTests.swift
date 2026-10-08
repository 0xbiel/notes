import XCTest
@testable import LectureCore

final class TranscriptionIntegrationTests: XCTestCase {
    private func transcribeFixture(_ extensionName: String) async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["NOTES_ASR_FIXTURES"],
              let runtimePath = ProcessInfo.processInfo.environment["NOTES_ASR_RUNTIME"] else {
            throw XCTSkip("Set NOTES_ASR_FIXTURES and NOTES_ASR_RUNTIME to test installed Whisper with invented lecture.wav and lecture.mp4 fixtures.")
        }
        let fixtures = URL(fileURLWithPath: fixturePath)
        let source = fixtures.appendingPathComponent("lecture." + extensionName)
        let original = try Data(contentsOf: source)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/ASR-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        let store = LocalMediaStore(workspace: workspace)
        let transcriber = WhisperTranscriber(store: store, runtimeRoot: URL(fileURLWithPath: runtimePath))
        var job = MediaJob(notebookID: "invented", subject: "Invented lecture", note: "Inicio.md", sourceName: source.lastPathComponent)
        job.whisperConfiguration = transcriber.preferredConfiguration
        XCTAssertTrue(transcriber.available(for: try XCTUnwrap(job.whisperConfiguration)))
        let copied = try await store.copySource(source, into: job) { _ in }
        job.sourceRelativePath = copied.path
        job.sourceDigest = copied.hash
        job.sourceCopyComplete = true
        let prepared = try await store.prepareAudio(for: job) { _ in }
        job.audioRelativePath = prepared.path
        job.duration = prepared.duration
        let playbackDuration = try await store.validateAudio(prepared.path)
        XCTAssertEqual(prepared.duration, playbackDuration, accuracy: 0.05)
        XCTAssertGreaterThan(job.duration, 30)
        do {
            _ = try await transcriber.transcribe(job) { checkpoint in
                try store.save(checkpoint)
                if checkpoint.completedChunks == 1 { throw CancellationError() }
            }
            XCTFail("Expected interruption after the first persisted chunk")
        } catch is CancellationError { }
        let interrupted = try XCTUnwrap(store.recoverJobs().first)
        XCTAssertEqual(interrupted.stage, .interrupted)
        XCTAssertEqual(interrupted.completedChunks, 1)
        XCTAssertFalse(interrupted.transcript.isEmpty)
        let result = try await transcriber.transcribe(interrupted) { checkpoint in try store.save(checkpoint) }
        for segment in interrupted.transcript {
            XCTAssertTrue(result.transcript.contains { $0.id == segment.id })
        }
        XCTAssertEqual(result.stage, .transcribed)
        XCTAssertEqual(result.completedChunks, Int(ceil(result.duration / 30)))
        XCTAssertFalse(result.transcript.isEmpty)
        XCTAssertEqual(Set(result.transcript.map(\.id)).count, result.transcript.count)
        XCTAssertTrue(result.transcript.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= result.duration + 0.5 })
        XCTAssertTrue(result.transcript.contains { $0.start >= 30 })
        let text = result.transcript.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("dos pasos"), text)
        XCTAssertTrue(text.contains("no tres"), text)
        XCTAssertTrue(text.contains("última frase"), text)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try store.fingerprint(copied.path), copied.hash)
        let recovered = try XCTUnwrap(store.load().first)
        XCTAssertEqual(recovered.transcript, result.transcript)
        let resumed = try await transcriber.transcribe(recovered) { checkpoint in try store.save(checkpoint) }
        XCTAssertEqual(resumed.transcript, result.transcript)
        XCTAssertEqual(resumed.completedChunks, result.completedChunks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: fixtures.appendingPathComponent("transcription-" + extensionName + ".json"), options: .atomic)
    }

    func testInstalledWhisperAudioImportAndCheckpointResume() async throws {
        try await transcribeFixture("wav")
    }

    func testInstalledWhisperVideoExtractionAndCheckpointResume() async throws {
        try await transcribeFixture("mp4")
    }
}
