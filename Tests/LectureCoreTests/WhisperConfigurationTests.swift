import XCTest
@testable import LectureCore

final class WhisperConfigurationTests: XCTestCase {
    func testNewAndLegacyRecoveryKeepDifferentCheckpointLayouts() throws {
        var job = MediaJob(notebookID: "fake", subject: "Inventado", note: "Inventado.md", sourceName: "Inventado.wav")
        let fresh = try WhisperConfiguration.resolved(for: job)
        XCTAssertEqual(fresh.importChunkSeconds, 30); XCTAssertFalse(fresh.conditionOnPreviousText)
        job.completedChunks = 2
        let legacy = try WhisperConfiguration.resolved(for: job)
        XCTAssertEqual(legacy.importChunkSeconds, 300); XCTAssertFalse(legacy.conditionOnPreviousText)
        job.whisperConfiguration = fresh
        let loaded = try JSONDecoder().decode(MediaJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(try WhisperConfiguration.resolved(for: loaded), fresh)
        job.whisperConfiguration = nil; job.live = LiveRecordingMetadata()
        XCTAssertEqual(try WhisperConfiguration.resolved(for: job).importChunkSeconds, 30)
    }
    func testLocalModelChoicesAndSafeArgumentsDoNotIntroducePromptsOrFetches() throws {
        let value = WhisperConfiguration(model: .largeV3Turbo)
        XCTAssertEqual(value.model.filename, "ggml-large-v3-turbo.bin")
        let arguments = value.arguments(model: URL(fileURLWithPath: "/fake/model.bin"), audio: URL(fileURLWithPath: "/fake/audio.wav"), output: URL(fileURLWithPath: "/fake/asr"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["-mc", "0"])
        XCTAssertFalse(arguments.contains("--prompt")); XCTAssertFalse(arguments.contains("-tr"))
        var job = MediaJob(notebookID: "fake", subject: "Inventado", note: "Inventado.md", sourceName: "Inventado.wav")
        for duration in [Double.nan, Double.infinity, 0, 301] {
            job.whisperConfiguration = .init(importChunkSeconds: duration)
            XCTAssertThrowsError(try WhisperConfiguration.resolved(for: job))
        }
    }
    func testDuplicateAudioNeverReusesIncompatibleTranscriptCheckpoints() throws {
        var old = MediaJob(notebookID: "fake", subject: "Inventado", note: "Inventado.md", sourceName: "Inventado.wav")
        old.completedChunks = 2
        var fresh = MediaJob(notebookID: "fake", subject: "Inventado", note: "Inventado.md", sourceName: "Inventado.wav")
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: old, for: fresh))
        fresh.whisperConfiguration = .init(model: .largeV3Turbo)
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: old, for: fresh))
        old.whisperConfiguration = .init(model: .small)
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: old, for: fresh))
        old.whisperConfiguration = fresh.whisperConfiguration
        XCTAssertTrue(WhisperConfiguration.canReuseTranscript(from: old, for: fresh))
        old.whisperConfiguration?.conditionOnPreviousText = true
        XCTAssertFalse(WhisperConfiguration.canReuseTranscript(from: old, for: fresh))
    }
    func testPreferredModelUsesInstalledLocalFilesAndKeepsLegacyModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/WhisperSelection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["original", "copied-course", "models", "runtime/whisper-build/bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        let transcriber = WhisperTranscriber(store: store)
        XCTAssertEqual(transcriber.preferredConfiguration.model, .small)
        // Empty fixture files only test availability selection; no decoder runs.
        try Data().write(to: transcriber.binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcriber.binary.path)
        try Data().write(to: transcriber.model(for: .init(model: .largeV3Turbo)))
        XCTAssertEqual(transcriber.preferredConfiguration.model, .largeV3Turbo)
        var old = MediaJob(notebookID: "fake", subject: "Inventado", note: "Inventado.md", sourceName: "Inventado.wav")
        old.completedChunks = 2
        XCTAssertEqual(try WhisperConfiguration.resolved(for: old).model, .small)
        try FileManager.default.removeItem(at: transcriber.model(for: .init(model: .largeV3Turbo)))
        XCTAssertEqual(transcriber.preferredConfiguration.model, .small)
    }
}
