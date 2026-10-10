import XCTest
@preconcurrency import AVFoundation
@testable import LectureCore

final class TranscriptionProviderTests: XCTestCase {
    func testAPIResponseOffsetsAndInvalidSegments() throws {
        let data = Data(#"{"segments":[{"start":0.5,"end":2,"text":" Hola "},{"start":-1,"end":1,"text":"invalid"},{"start":1,"end":99,"text":"outside"},{"start":2,"end":3,"text":" "}]}"#.utf8)
        let segments = try APIAudioTranscriber.decode(data, offset: 28, duration: 32, chunk: 1)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id, "1-0")
        XCTAssertEqual(segments[0].start, 28.5)
        XCTAssertEqual(segments[0].text, "Hola")
    }
    func testAPIRequestAndSafeAuthenticationFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("RIFF-test-audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let client = APIAudioTranscriber(readKey: { "test-only-placeholder" }, upload: { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-placeholder")
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("whisper-1")); XCTAssertTrue(text.contains("verbose_json"))
            XCTAssertTrue(text.contains("audio/wav")); XCTAssertTrue(text.contains("RIFF-test-audio"))
            XCTAssertFalse(text.contains("name=\"language\""))
            return (Data("Do not expose raw provider errors".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await client.transcribe(audio: file, offset: 0, duration: 5, chunk: 0, language: "auto"); XCTFail("Expected auth error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Clave OpenAI")); XCTAssertFalse(error.localizedDescription.contains("raw provider")) }
        let missing = APIAudioTranscriber(readKey: { nil }, upload: { _, _ in XCTFail("Must not upload without a key"); throw CancellationError() })
        do { _ = try await missing.transcribe(audio: file, offset: 0, duration: 5, chunk: 0, language: "es"); XCTFail("Expected missing key") } catch { XCTAssertTrue(error.localizedDescription.contains("Preferencias")) }
    }
    func testProviderAndLanguageCannotReuseOtherTranscript() {
        var original = MediaJob(notebookID: "test", subject: "test", note: "test.md", sourceName: "test.wav")
        original.whisperConfiguration = WhisperConfiguration()
        var other = original
        XCTAssertTrue(WhisperConfiguration.canReuseTranscript(from: original, for: other))
        other.live = LiveRecordingMetadata()
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: original, for: other))
        other.live = nil
        other.transcriptionProvider = .openAI
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: original, for: other))
        other.transcriptionProvider = .local; other.transcriptionLanguage = "ca"
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: original, for: other))
    }
    func testFiveSecondDictationSealsAndRecoversTail() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/dictation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        var job = MediaJob(notebookID: "test", subject: "test", note: "test.md", sourceName: "Mic", microphone: true)
        job.liveChunkSeconds = 5
        let recorder = try RollingPCMRecorder(store: store, job: job)
        for _ in 0..<6 { try recorder.appendPCM16(Data(repeating: 0, count: 32_000)) }
        XCTAssertEqual(recorder.snapshot.chunks.count, 1)
        XCTAssertEqual(recorder.snapshot.chunks[0].end, 5)
        let final = try recorder.finish()
        XCTAssertEqual(final.chunks.count, 2)
        XCTAssertEqual(final.chunks[1].start, 3)
        XCTAssertEqual(final.chunks[1].end, 6)
        XCTAssertEqual(try RollingPCMRecorder.recover(store: store, job: job).chunks.count, 2)
    }
    func testModelManagerInstallationLifecycle() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTES_MODEL_INSTALL_TEST"] else { throw XCTSkip("Explicit model download/runtime installation test") }
        let root = URL(fileURLWithPath: path)
        let installer = TranscriptionModelInstaller(root: root)
        try await installer.installRuntime()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("runtime/whisper-build/bin/whisper-cli").path))
        try await installer.install(.small)
        let model = root.appendingPathComponent("models/ggml-small.bin")
        let size = try model.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(size, 487_601_967)
        // Exercise atomic replacement on an existing installed model.
        try await installer.install(.small)
        let backup = root.appendingPathComponent("models/.test-backup.bin")
        try FileManager.default.copyItem(at: model, to: backup)
        defer { try? FileManager.default.moveItem(at: backup, to: model) }
        try installer.uninstall(.small)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        try FileManager.default.moveItem(at: backup, to: model)
    }
    func testRealAudioThroughLiveDictationPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOTES_LIVE_SAMPLE"], let runtime = env["NOTES_ASR_RUNTIME"] else { throw XCTSkip("Explicit live pipeline sample test") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/live-sample-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        var job = MediaJob(notebookID: "live-test", subject: "Dictation", note: "Dictation.md", sourceName: "Live sample", microphone: true)
        job.liveChunkSeconds = 5; job.transcriptionProvider = .local; job.whisperConfiguration = WhisperConfiguration(model: .small)
        let recorder = try RollingPCMRecorder(store: store, job: job)
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let converter = try PCMStreamConverter(format: input.processingFormat) { data in try recorder.appendPCM16(data) }
        let transcriber = WhisperTranscriber(store: store, runtimeRoot: URL(fileURLWithPath: runtime))
        let frames = AVAudioFramePosition(12 * input.processingFormat.sampleRate)
        var processed = 0
        while input.framePosition < min(frames, input.length) {
            let count = AVAudioFrameCount(min(4096, min(frames, input.length) - input.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count))
            try input.read(into: buffer, frameCount: count); try converter.consume(buffer)
            if recorder.snapshot.chunks.count > processed {
                XCTAssertFalse(recorder.snapshot.closed)
                let chunk = recorder.snapshot.chunks[processed]
                let segments = try await transcriber.transcribeLiveChunk(chunk, job: job)
                job.transcript = TranscriptMerge.append(segments, to: job.transcript); processed += 1
            }
        }
        try converter.finish()
        let closed = try recorder.finish()
        for chunk in closed.chunks.dropFirst(processed) {
            let segments = try await transcriber.transcribeLiveChunk(chunk, job: job)
            job.transcript = TranscriptMerge.append(segments, to: job.transcript)
        }
        XCTAssertEqual(closed.chunks.count, 3)
        XCTAssertGreaterThan(processed, 0)
        XCTAssertFalse(job.transcript.isEmpty)
        XCTAssertEqual(Set(job.transcript.map(\.id)).count, job.transcript.count)
        print("LIVE_SAMPLE beforeStop=\(processed) totalChunks=\(closed.chunks.count) segments=\(job.transcript.count)")
    }
    func testRealClassAudioLocalOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let audio = env["NOTES_LOCAL_CLASS_AUDIO"], let runtime = env["NOTES_ASR_RUNTIME"] else { throw XCTSkip("Explicit local-only class audio test") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/class-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        let source = URL(fileURLWithPath: audio)
        let before = try Data(contentsOf: source)
        var job = MediaJob(notebookID: "class-test", subject: "Class", note: "Class.md", sourceName: source.lastPathComponent)
        job.transcriptionProvider = .local; job.whisperConfiguration = WhisperConfiguration(model: .largeV3Turbo)
        let copy = try await store.copySource(source, into: job) { _ in }
        job.sourceRelativePath = copy.path; job.sourceCopyComplete = true; job.sourceDigest = copy.hash
        let prepared = try await store.prepareAudio(for: job) { _ in }
        job.audioRelativePath = prepared.path; job.duration = prepared.duration
        let transcriber = WhisperTranscriber(store: store, runtimeRoot: URL(fileURLWithPath: runtime))
        let result = try await transcriber.transcribe(job) { value in
            if value.completedChunks % 10 == 0 { print("CLASS_AUDIO completed=\(value.completedChunks)") }
        }
        XCTAssertEqual(result.stage, .transcribed); XCTAssertFalse(result.transcript.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let resumed = try await transcriber.transcribe(result) { _ in }
        XCTAssertEqual(resumed.transcript, result.transcript)
        print("CLASS_AUDIO duration=\(result.duration) chunks=\(result.completedChunks) segments=\(result.transcript.count) output=\(root.path)")
    }
}
