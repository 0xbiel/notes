import XCTest
@testable import LectureCore

final class VoiceSegmenterTests: XCTestCase {
    /// A voiced tone, or room noise far below it.
    private func audio(_ seconds: Double, speech: Bool) -> Data {
        var data = Data(capacity: Int(seconds * 32_000))
        for index in 0..<Int(seconds * 16_000) {
            let value = speech ? sin(Double(index) * 2 * .pi * 220 / 16_000) * 0.2 : Double.random(in: -0.0008...0.0008)
            withUnsafeBytes(of: Int16(value * 32_767).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
    private func feed(_ segmenter: inout VoiceSegmenter, _ data: Data) -> [VoiceSegmenter.Segment] {
        var segments: [VoiceSegmenter.Segment] = [], offset = 0
        while offset < data.count { let count = min(4096, data.count - offset); segments += segmenter.append(data.subdata(in: offset..<(offset + count))); offset += count }
        return segments
    }

    func testUtterancesSplitAtPausesWithoutOverlapOrSilence() {
        var segmenter = VoiceSegmenter()
        let segments = feed(&segmenter, audio(1, speech: false) + audio(1.5, speech: true) + audio(1, speech: false) + audio(2, speech: true) + audio(3, speech: false))
        XCTAssertEqual(segments.count, 2)
        // A short lead-in before the first word, and the pause that ended the phrase after it.
        XCTAssertEqual(Double(segments[0].start) / 16_000, 0.7, accuracy: 0.05)
        XCTAssertEqual(Double(segments[0].frames) / 16_000, 0.3 + 1.5 + 0.6, accuracy: 0.06)
        XCTAssertGreaterThanOrEqual(segments[1].start, segments[0].start + segments[0].frames)
        XCTAssertEqual(Double(segments[1].start + segments[1].frames) / 16_000, 5.5 + 0.6, accuracy: 0.06)
        XCTAssertTrue(segmenter.heardSpeech)
        XCTAssertEqual(segmenter.silentSeconds, 3, accuracy: 0.06)
        XCTAssertNil(segmenter.finish())
        let limit = MicrophoneStream.SilenceLimit()
        XCTAssertTrue(limit.reached(heard: segmenter.heardSpeech, silent: segmenter.silentSeconds))
        XCTAssertFalse(limit.reached(heard: true, silent: 1.5))
    }

    func testBriefWordWaitsToJoinTheNextPhrase() {
        var segmenter = VoiceSegmenter()
        let segments = feed(&segmenter, audio(1, speech: false) + audio(0.4, speech: true) + audio(1.4, speech: false) + audio(2, speech: true) + audio(1, speech: false))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(Double(segments[0].start) / 16_000, 0.7, accuracy: 0.05)
        XCTAssertEqual(Double(segments[0].frames) / 16_000, 0.3 + 0.4 + 1.4 + 2 + 0.6, accuracy: 0.06)
        // Alone, it is still delivered before the dictation stops by itself.
        var alone = VoiceSegmenter()
        XCTAssertEqual(feed(&alone, audio(1, speech: false) + audio(0.4, speech: true) + audio(2.2, speech: false)).count, 1)
    }

    func testSilenceAndClicksProduceNothing() {
        var segmenter = VoiceSegmenter()
        let click = audio(0.04, speech: true)
        XCTAssertTrue(feed(&segmenter, audio(4, speech: false) + click + audio(4, speech: false) + click + audio(4, speech: false)).isEmpty)
        XCTAssertFalse(segmenter.heardSpeech)
        XCTAssertNil(segmenter.finish())
        XCTAssertEqual(segmenter.silentSeconds, 12.08, accuracy: 0.05)
        XCTAssertTrue(MicrophoneStream.SilenceLimit().reached(heard: false, silent: segmenter.silentSeconds))
        XCTAssertFalse(MicrophoneStream.SilenceLimit().reached(heard: false, silent: 6))
    }

    func testUnbrokenSpeechIsCutOnceAtTheLimitAndContinuesSeamlessly() {
        var segmenter = VoiceSegmenter()
        var segments = feed(&segmenter, audio(30, speech: true))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(Double(segments[0].frames) / 16_000, 28, accuracy: 0.01)
        if let last = segmenter.finish() { segments.append(last) }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[1].start, segments[0].start + segments[0].frames)
        XCTAssertEqual(segments[0].frames + segments[1].frames, 30 * 16_000)
    }

    func testQuietSpeechOverSteadyNoiseStillCounts() {
        var segmenter = VoiceSegmenter()
        var quiet = Data()
        for index in 0..<32_000 {
            let value = sin(Double(index) * 2 * .pi * 180 / 16_000) * 0.012
            withUnsafeBytes(of: Int16(value * 32_767).littleEndian) { quiet.append(contentsOf: $0) }
        }
        XCTAssertEqual(feed(&segmenter, audio(1, speech: false) + quiet + audio(1, speech: false)).count, 1)
    }

    func testRecorderWritesOneClipPerUtteranceAndKeepsTheWholeRecording() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        var job = MediaJob(notebookID: "synthetic-live", subject: "Inventado", note: "", sourceName: "Synthetic PCM", microphone: true)
        job.live = LiveRecordingMetadata(); job.liveChunkSeconds = 5; job.liveVoiceSegments = true
        let recorder = try RollingPCMRecorder(store: store, job: job)
        let stream = audio(1, speech: false) + audio(2, speech: true) + audio(1, speech: false) + audio(0.3, speech: true)
        var offset = 0
        while offset < stream.count { let count = min(4096, stream.count - offset); try recorder.appendPCM16(stream.subdata(in: offset..<(offset + count))); offset += count }
        XCTAssertEqual(recorder.snapshot.chunks.count, 1)
        XCTAssertEqual(recorder.voice?.heard, true)
        let state = try recorder.finish()
        XCTAssertTrue(state.closed); XCTAssertEqual(state.duration, 4.3, accuracy: 0.001)
        XCTAssertEqual(state.chunks.count, 2)
        XCTAssertLessThanOrEqual(state.chunks[0].end, state.chunks[1].start)
        XCTAssertEqual(state.chunks[1].end, 4.3, accuracy: 0.03)
        // The short last utterance is padded to the length Whisper needs; its times stay true.
        XCTAssertEqual(state.chunks[1].end - state.chunks[1].start, 0.6, accuracy: 0.06)
        let last = try await store.validateAudio(state.chunks[1].path)
        XCTAssertEqual(last, 1.2, accuracy: 0.01)
        for chunk in state.chunks { XCTAssertEqual(try store.fingerprint(chunk.path), chunk.digest) }
        XCTAssertEqual(try Data(contentsOf: store.url(state.source)).dropFirst(44), stream)
        XCTAssertEqual(try RollingPCMRecorder.load(store: store, job: job).chunks.count, 2)
    }

    func testGPUArgumentsAndSavedRecordingsStayOnCPU() throws {
        var value = WhisperConfiguration()
        let urls = (URL(fileURLWithPath: "/m"), URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/o"))
        XCTAssertTrue(value.arguments(model: urls.0, audio: urls.1, output: urls.2).contains("-ng"))
        value.useGPU = true
        let arguments = value.arguments(model: urls.0, audio: urls.1, output: urls.2)
        XCTAssertFalse(arguments.contains("-ng"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-t")! + 1], "4")
        let legacy = try JSONDecoder().decode(WhisperConfiguration.self, from: Data(#"{"model":"small","importChunkSeconds":30,"conditionOnPreviousText":false}"#.utf8))
        XCTAssertNil(legacy.useGPU)
        XCTAssertTrue(WhisperTranscriber.isAnnotation("[BLANK_AUDIO]")); XCTAssertTrue(WhisperTranscriber.isAnnotation("(música)")); XCTAssertTrue(WhisperTranscriber.isAnnotation("…"))
        XCTAssertFalse(WhisperTranscriber.isAnnotation("Hola (bueno) vale"))
    }

    /// Set NOTES_DOWNLOAD_URL (and NOTES_DOWNLOAD_BYTES) to watch a real download report its progress.
    func testDownloadReportsProgress() async throws {
        guard let address = ProcessInfo.processInfo.environment["NOTES_DOWNLOAD_URL"], let url = URL(string: address) else { throw XCTSkip("Set NOTES_DOWNLOAD_URL.") }
        let expected = Int64(ProcessInfo.processInfo.environment["NOTES_DOWNLOAD_BYTES"] ?? "") ?? 0
        let seen = Seen()
        let (file, _) = try await ProgressDownload.run(url, expected: expected) { seen.add($0) }
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let values = seen.values
        print("DOWNLOAD", size, "bytes,", values.count, "reports, fractions", values.prefix(3).map(\.fraction), "…", values.suffix(2).map(\.fraction))
        XCTAssertGreaterThan(size, 0)
        XCTAssertEqual(values.last?.fraction, 1)
        XCTAssertEqual(values.map(\.received), values.map(\.received).sorted())
        if expected > 0 { XCTAssertEqual(size, expected); XCTAssertGreaterThanOrEqual(values.count, 2) }
    }
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var items: [DownloadProgress] = []
        func add(_ value: DownloadProgress) { lock.lock(); items.append(value); lock.unlock() }
        var values: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Set NOTES_DICTATION_SAMPLE to a 16 kHz mono PCM16 WAV and NOTES_WHISPER_ROOT to a workspace
    /// with the runtime and small model to hear how a real recording is cut and recognised.
    func testReplayRecordingThroughPauseSegmentsAndGPU() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["NOTES_DICTATION_SAMPLE"], let runtime = environment["NOTES_WHISPER_ROOT"] else { throw XCTSkip("Set NOTES_DICTATION_SAMPLE and NOTES_WHISPER_ROOT.") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        var job = MediaJob(notebookID: "replay", subject: "Replay", note: "", sourceName: "Replay", microphone: true)
        job.live = LiveRecordingMetadata(); job.liveChunkSeconds = 5; job.liveVoiceSegments = true
        job.transcriptionLanguage = environment["NOTES_DICTATION_LANGUAGE"] ?? "auto"
        job.whisperConfiguration = WhisperConfiguration(); job.whisperConfiguration?.useGPU = true
        let recorder = try RollingPCMRecorder(store: store, job: job)
        let stream = try Data(contentsOf: URL(fileURLWithPath: sample)).dropFirst(44)
        var offset = stream.startIndex, stopped: Double?
        while offset < stream.endIndex {
            let count = min(4096, stream.endIndex - offset); try recorder.appendPCM16(Data(stream[offset..<(offset + count)])); offset += count
            if stopped == nil, let voice = recorder.voice, MicrophoneStream.SilenceLimit().reached(heard: voice.heard, silent: voice.silent) { stopped = recorder.snapshot.duration }
        }
        let state = try recorder.finish()
        print("REPLAY auto-stop at", stopped.map { String(format: "%.1f s", $0) } ?? "never", "of", state.duration)
        let transcriber = WhisperTranscriber(store: store, runtimeRoot: URL(fileURLWithPath: runtime))
        let started = Date()
        for chunk in state.chunks {
            let segments = try await transcriber.transcribeLiveChunk(chunk, job: job)
            print("REPLAY", String(format: "%.1f–%.1f", chunk.start, chunk.end), segments.map(\.text).joined(separator: " "))
        }
        print("REPLAY transcribed", state.chunks.count, "clips in", String(format: "%.1f s", Date().timeIntervalSince(started)))
    }
}
