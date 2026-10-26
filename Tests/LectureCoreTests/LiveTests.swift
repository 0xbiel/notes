import XCTest
@preconcurrency import AVFoundation
@testable import LectureCore

final class LiveTests: XCTestCase {
    private func environment(duration: Double = 28_800) throws -> (LocalMediaStore, MediaJob, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))); store.maximumDuration = duration
        var job = MediaJob(notebookID: "synthetic-live", subject: "Inventado", note: "Inventado.md", sourceName: "Synthetic PCM")
        job.live = LiveRecordingMetadata(); return (store, job, root)
    }
    private func feed(_ recorder: RollingPCMRecorder, seconds: Double) throws {
        var frames = Int(seconds * 16_000)
        while frames > 0 { let count = min(4096, frames); try recorder.appendPCM16(Data(repeating: 1, count: count * 2)); frames -= count }
    }
    func testContinuousAudioExactChunksOverlapAndNoExtraAtBoundary() async throws {
        let (store, job, _) = try environment(); let recorder = try RollingPCMRecorder(store: store, job: job)
        try feed(recorder, seconds: 90); let state = try recorder.finish()
        XCTAssertEqual(state.duration, 90); XCTAssertEqual(state.chunks.count, 3); XCTAssertTrue(state.closed)
        XCTAssertEqual(state.chunks.map(\.start), [0, 28, 58]); XCTAssertEqual(state.chunks.map(\.end), [30, 60, 90])
        let sourceDuration = try await store.validateAudio(state.source)
        XCTAssertEqual(sourceDuration, 90, accuracy: 0.01)
        for chunk in state.chunks { let duration = try await store.validateAudio(chunk.path); XCTAssertEqual(duration, chunk.end - chunk.start, accuracy: 0.01); XCTAssertEqual(try store.fingerprint(chunk.path), chunk.digest) }
        let source = try Data(contentsOf: store.url(state.source))
        XCTAssertEqual(source.count, 44 + 90 * 32_000); XCTAssertTrue(source.dropFirst(44).allSatisfy { $0 == 1 })
        XCTAssertThrowsError(try recorder.appendPCM16(Data(count: 2)))
        XCTAssertEqual(try recorder.finish().chunks.count, 3)
    }
    func testShortFinalTailAndExplicitCrashRecoveryPreserveEveryAudioByte() async throws {
        let (store, job, _) = try environment(); var recorder: RollingPCMRecorder? = try RollingPCMRecorder(store: store, job: job)
        try feed(recorder!, seconds: 49)
        let source = recorder!.sourcePath
        let bytes = try Data(contentsOf: store.url(source)).dropFirst(44)
        recorder = nil // Simulate process loss without normal finalization.
        let recovered = try RollingPCMRecorder.recover(store: store, job: job)
        XCTAssertTrue(recovered.closed); XCTAssertEqual(recovered.duration, 49); XCTAssertEqual(recovered.chunks.count, 2)
        XCTAssertEqual(recovered.chunks.last?.start, 28); XCTAssertEqual(recovered.chunks.last?.end, 49)
        XCTAssertEqual(try Data(contentsOf: store.url(source)).dropFirst(44), bytes)
        let duration = try await store.validateAudio(source)
        XCTAssertEqual(duration, 49, accuracy: 0.01)
        XCTAssertEqual(try RollingPCMRecorder.recover(store: store, job: job).chunks.count, 2)
    }
    func testResourceDurationAndBufferBoundsStopWithoutDeletingSavedAudio() throws {
        let (store, job, _) = try environment(duration: 35)
        let recorder = try RollingPCMRecorder(store: store, job: job)
        XCTAssertThrowsError(try recorder.appendPCM16(Data(count: 65_538)))
        XCTAssertThrowsError(try recorder.appendPCM16(Data(count: 3)))
        XCTAssertThrowsError(try feed(recorder, seconds: 40))
        let state = recorder.snapshot
        XCTAssertTrue(state.closed); XCTAssertEqual(state.duration, 35); XCTAssertEqual(state.chunks.count, 2)
        XCTAssertEqual(try store.sourceSize(store.url(state.source)), 44 + 35 * 32_000)
        XCTAssertEqual(RollingPCMRecorder.maximumPendingInference, 8)
        XCTAssertLessThan(UInt64(28_800 * 32_000 * 2), 8 * 1024 * 1024 * 1024)
    }
    func testOverlapDedupKeepsNegationHypothesesAndStableIDs() {
        let old: [MediaTranscriptSegment] = [.init(id: "0-0", start: 20, end: 30, text: "El concepto A tiene tres pasos")]
        let new: [MediaTranscriptSegment] = [
            .init(id: "1-0", start: 28, end: 32, text: "tiene tres pasos y se revisa después"),
            .init(id: "1-1", start: 31, end: 40, text: "No, corrijo: tiene dos pasos")
        ]
        let merged = TranscriptMerge.append(new, to: old)
        XCTAssertEqual(merged.count, 3); XCTAssertEqual(merged[1].text, "y se revisa después")
        XCTAssertTrue(merged[2].text.contains("No, corrijo")); XCTAssertEqual(TranscriptMerge.append(new, to: merged), merged)
        let alternative = TranscriptMerge.append([.init(id: "other", start: 28, end: 30, text: "El concepto no tiene tres pasos")], to: old)
        XCTAssertEqual(alternative.count, 2); XCTAssertEqual(alternative.last?.boundaryReview, true)
        XCTAssertEqual(TranscriptMerge.append([.init(id: "repeat", start: 28, end: 30, text: "El concepto A tiene tres pasos")], to: old).count, 1)
    }
    func testOptionalLiveFieldsLoadOlderPersistedTranscriptsAndJobs() throws {
        let data = Data(#"{"id":"old","start":0,"end":1,"text":"Negación conservada"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MediaTranscriptSegment.self, from: data).boundaryReview)
        let (_, job, _) = try environment()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any]); old.removeValue(forKey: "live")
        XCTAssertNil(try JSONDecoder().decode(MediaJob.self, from: JSONSerialization.data(withJSONObject: old)).live)
    }
    func testStreamingResamplerDrainsFinalAudioWithoutOpeningDevice() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        var data = Data()
        let converter = try PCMStreamConverter(format: format) { data.append($0) }
        var remaining = 48_000
        while remaining > 0 {
            let count = min(4096, remaining)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count { buffer.floatChannelData![0][frame] = 0.25 }
            try converter.consume(buffer); remaining -= count
        }
        let before = data.count
        try converter.finish()
        XCTAssertGreaterThanOrEqual(data.count, before)
        XCTAssertEqual(data.count / 2, 16_000, accuracy: 2)
        let after = data.count; try converter.finish(); XCTAssertEqual(data.count, after)
    }
    func testDecoderRepetitionIsFlaggedButOrdinaryCorrectionIsPreserved() {
        let repeated: [MediaTranscriptSegment] = (0..<4).map { (index: Int) -> MediaTranscriptSegment in
            let start = Double(index) * 3
            return MediaTranscriptSegment(id: "r\(index)", start: start, end: start + 3, text: "La figura inventada contiene cinco elementos.")
        }
        XCTAssertNotNil(ASRQuality.repetitionWarning(repeated))
        XCTAssertNotNil(ASRQuality.repetitionWarning([.init(id: "loop", start: 0, end: 10, text: Array(repeating: "El dragón azul tiene cuatro alas", count: 4).joined(separator: ", "))]))
        let correction = [.init(id: "a", start: 0, end: 5, text: "Son tres pasos."), MediaTranscriptSegment(id: "b", start: 5, end: 10, text: "No, corrijo: son dos pasos. Esto no lo copiéis todavía.")]
        XCTAssertNil(ASRQuality.repetitionWarning(correction))
        XCTAssertEqual(correction.last?.text, "No, corrijo: son dos pasos. Esto no lo copiéis todavía.")
    }
}
