import XCTest
@testable import LectureCore

/// Explicit opt-in only: supplied real audio stays in an ignored local workspace.
final class RealRecordingIntegrationTests: XCTestCase {
    func testRealRecordingTranscriptionAndCodexEdits() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["NOTES_REAL_AUDIO"], let runtimePath = env["NOTES_ASR_RUNTIME"],
              let outputPath = env["NOTES_REAL_OUTPUT"], env["NOTES_REAL_CODEX_SEND"] == "1" else {
            throw XCTSkip("Supply NOTES_REAL_AUDIO, NOTES_ASR_RUNTIME, NOTES_REAL_OUTPUT and NOTES_REAL_CODEX_SEND=1 to authorize real transcript sending.")
        }
        let root = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: sourcePath)
        let original = try Data(contentsOf: source)
        let workspace = try SafeWorkspace(root: root, originalRoot: source.deletingLastPathComponent())
        let store = LocalMediaStore(workspace: workspace)
        let transcriber = WhisperTranscriber(store: store, runtimeRoot: URL(fileURLWithPath: runtimePath))
        let initial = "# Apuntes de la grabación\n"
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("copied-course/Grabacion.md").path) {
            try workspace.createNote("Grabacion.md", text: initial)
        }
        var job: MediaJob
        if let saved = try store.recoverJobs().first { job = saved }
        else {
            job = MediaJob(notebookID: "real-test", subject: "Grabación real", note: "Grabacion.md", sourceName: source.lastPathComponent)
            job.whisperConfiguration = transcriber.preferredConfiguration
            let copied = try await store.copySource(source, into: job) { _ in }
            job.sourceRelativePath = copied.path; job.sourceDigest = copied.hash; job.sourceCopyComplete = true
            let audio = try await store.prepareAudio(for: job) { _ in }
            job.audioRelativePath = audio.path; job.duration = audio.duration
            try store.save(job)
        }
        let started = Date()
        let result = try await transcriber.transcribe(job) { checkpoint in
            print("REAL_ASR chunks=\(checkpoint.completedChunks) duration=\(checkpoint.duration)")
        }
        XCTAssertEqual(result.stage, .transcribed)
        XCTAssertFalse(result.transcript.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try store.fingerprint(try XCTUnwrap(result.sourceRelativePath)), result.sourceDigest)
        let resumed = try await transcriber.transcribe(result) { _ in }
        XCTAssertEqual(resumed.transcript, result.transcript)
        let transcript = result.transcript.map { "[\(Int($0.start))–\(Int($0.end))] \($0.text)" }.joined(separator: "\n\n")
        try transcript.write(to: root.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        var configuration = AIProviderSettings().codexCLI
        configuration.model = "gpt-6-luna"; configuration.reasoningEffort = "low"
        configuration.fastMode = true; configuration.accountSendingAllowed = true
        let outbox = try AIOutbox(workspace: workspace)
        let editor = try NotebookEditor(workspace: workspace)
        let historyStart = editor.history.count
        // Even a provider failure must leave the isolated note at its baseline.
        defer {
            while editor.history.dropFirst(historyStart).contains(where: { !$0.undone }) {
                do { _ = try editor.undo() } catch { XCTFail("Could not restore test note: \(error)"); break }
            }
        }
        var sent = 0; var applied = 0
        // Sample substantive groups across the lecture; short silence hallucinations
        // and closing asides cannot exercise note editing.
        let groups = AIOutbox.groups(result.transcript, flush: true).filter {
            $0.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count >= 70
        }
        guard !groups.isEmpty else { throw MediaError.invalid("No substantive transcript groups to test editing.") }
        for index in Set([0, groups.count / 2, groups.count - 1]).sorted() {
            let before = try workspace.readNote(result.targetNote)
            var batch = try outbox.enqueue(media: result, selected: groups[index])
            batch.providerConfiguration = configuration; batch.model = configuration.model
            try outbox.replace(batch)
            let ready = try await NotesProviderTransport(store: store).send(batch, configuration: configuration)
            XCTAssertEqual(ready.stage, .ready)
            XCTAssertEqual(try workspace.readNote(result.targetNote), before)
            try outbox.replace(ready); sent += 1
            for decision in ready.decisions where [.add, .correct, .priority].contains(decision.action) {
                _ = try outbox.apply(batchID: ready.id, proposalID: decision.id, text: decision.text, quote: decision.targetQuote, editor: editor, hasDraft: false)
                applied += 1
            }
            print("REAL_CODEX batch=\(sent) decisions=\(ready.decisions.count) applied=\(applied)")
        }
        guard applied > 0 else { throw MediaError.invalid("Generation completed but no eligible edits were proposed; editing and undo are unverified.") }
        let after = try workspace.readNote(result.targetNote)
        XCTAssertNotEqual(after, initial)
        XCTAssertEqual(try NotebookEditor(workspace: workspace).history, editor.history)
        try after.write(to: root.appendingPathComponent("edited-note.md"), atomically: true, encoding: .utf8)
        for _ in 0..<applied { _ = try editor.undo() }
        XCTAssertEqual(try workspace.readNote(result.targetNote), initial)
        let report = "duration_seconds=\(result.duration)\nchunks=\(result.completedChunks)\nsegments=\(result.transcript.count)\nbatches=\(sent)\nedits=\(applied)\nmodel=gpt-6-luna\nfast_mode_requested=true\nundo_verified=true\nsource_unchanged=true\nelapsed_seconds=\(Date().timeIntervalSince(started))\nasr_warning=\(result.asrQualityWarning ?? "none")\n"
        try report.write(to: root.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
