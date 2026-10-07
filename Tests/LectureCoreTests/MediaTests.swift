import XCTest
@testable import LectureCore

final class MediaTests: XCTestCase {
    private func environment() throws -> (LocalMediaStore, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))), root)
    }
    private func wav(_ seconds: Int) -> Data {
        var result = Data()
        func text(_ value: String) { result.append(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        let bytes = seconds * 16_000 * 2
        text("RIFF"); number(UInt32(bytes + 36)); text("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000)); number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(bytes)); result.append(Data(count: bytes)); return result
    }
    func testImportPreservesSourceAndFingerprintAndExtractsPlayableAudio() async throws {
        let (store, root) = try environment(); let data = wav(2); let source = root.appendingPathComponent("synthetic.wav")
        try data.write(to: source); var job = MediaJob(notebookID: "test", subject: "Prueba", note: "Tema.md", sourceName: source.lastPathComponent)
        let copied = try await store.copySource(source, into: job) { _ in }
        XCTAssertEqual(try Data(contentsOf: source), data); XCTAssertEqual(try store.fingerprint(copied.path), copied.hash)
        job.sourceCopyComplete = true; job.sourceRelativePath = copied.path
        let prepared = try await store.prepareAudio(for: job) { _ in }
        XCTAssertEqual(prepared.duration, 2, accuracy: 0.05); XCTAssertEqual(try Data(contentsOf: source), data)
        let pcm = try store.destination(for: job, name: "converted.wav")
        try WhisperTranscriber.convertPCM(source: store.url(prepared.path), output: pcm.url, duration: 2)
        let pcmDuration = try await store.validateAudio(pcm.relative)
        XCTAssertEqual(pcmDuration, 2, accuracy: 0.05)
    }
    func testCancellationRemovesPartialAndLeavesSourceUntouched() async throws {
        let (store, root) = try environment(); let source = root.appendingPathComponent("large.wav"); let data = Data(count: 4 * 1024 * 1024)
        try data.write(to: source); let job = MediaJob(notebookID: "test", subject: "Prueba", note: "Tema.md", sourceName: "large.wav")
        let task = Task.detached { try await store.copySource(source, into: job) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), data)
        let folder = try store.destination(for: job, name: "unused.wav").url.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
    func testRecoveryKeepsDateTagsAndCheckpoints() throws {
        let (store, _) = try environment(); var job = MediaJob(notebookID: "test", subject: "Prueba", note: "Tema.md", sourceName: "Clase.mp4")
        job.classDate = Date(timeIntervalSince1970: 100); job.importedAt = Date(timeIntervalSince1970: 200); job.unitTags = ["Unidad 2"]; job.examTags = ["Parcial"]
        job.stage = .transcribing; job.completedChunks = 2; job.transcript = [.init(id: "1", start: 0, end: 30, text: "Texto")]
        try store.save(job); let recovered = try XCTUnwrap(store.recoverJobs().first)
        XCTAssertEqual(recovered.stage, .interrupted); XCTAssertEqual(recovered.completedChunks, 2); XCTAssertEqual(recovered.classDate, job.classDate); XCTAssertEqual(recovered.importedAt, job.importedAt); XCTAssertEqual(recovered.transcript, job.transcript); XCTAssertEqual(recovered.unitTags, job.unitTags)
    }
    func testGuardsSizeCorruptAudioAndUnsafePaths() async throws {
        var (store, root) = try environment(); let source = root.appendingPathComponent("invalid.mp4"); try Data("not a movie".utf8).write(to: source)
        store.maximumBytes = 2; XCTAssertThrowsError(try store.sourceSize(source))
        for path in ["../escape.wav", "/tmp/escape.wav", "a/.hidden", "a/../escape.wav"] { XCTAssertThrowsError(try store.url(path)) }
        let target = try store.destination(for: MediaJob(notebookID: "t", subject: "t", note: "t.md", sourceName: "x"), name: "corrupt.mp4")
        try Data("not a movie".utf8).write(to: target.url)
        do { _ = try await store.validateAudio(target.relative); XCTFail("Corrupt audio accepted") } catch { }
    }
    func testWhisperOffsetsAndEmptySegments() throws {
        let data = Data(#"{"transcription":[{"offsets":{"from":2000,"to":3500},"text":" Hola "},{"offsets":{"from":3500,"to":4000},"text":" "}]}"#.utf8)
        let result = try WhisperTranscriber.decode(data, offset: 298, chunk: 1)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.start, 300); XCTAssertEqual(result.first?.end, 301.5); XCTAssertEqual(result.first?.text, "Hola")
    }
}
