import SwiftUI
import LectureCore
@preconcurrency import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MediaController: ObservableObject {
    @Published var jobs: [MediaJob] = []
    @Published var selectedID: String?
    @Published var isRecording = false
    @Published var busy = false
    @Published var playing = false
    @Published var position = 0.0
    @Published var error: String?
    let store: LocalMediaStore
    var onTranscriptUpdate: ((MediaJob) -> Void)?
    private var worker: Task<Void, Never>?
    private var recorder: MicrophoneStream?
    private var liveWorker: Task<Void, Never>?
    private var hashing = false
    private var player: AVPlayer?
    private var timer: Task<Void, Never>?
    private var recordingID: String?
    var selected: MediaJob? { jobs.first { $0.id == selectedID } }
    func whisperConfiguration(for job: MediaJob) -> WhisperConfiguration? {
        if job.whisperConfiguration == nil, job.completedChunks == 0 {
            return WhisperTranscriber(store: store).preferredConfiguration
        }
        return try? WhisperConfiguration.resolved(for: job)
    }
    var whisperAvailable: Bool {
        let transcriber = WhisperTranscriber(store: store)
        if let selected {
            guard let configuration = whisperConfiguration(for: selected) else { return false }
            return transcriber.available(for: configuration)
        }
        return transcriber.available(for: transcriber.preferredConfiguration)
    }
    init(workspace: SafeWorkspace) throws {
        store = LocalMediaStore(workspace: workspace); jobs = try store.recoverJobs(); selectedID = jobs.first?.id
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let recorder = self.recorder, let id = self.recordingID, let index = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[index].duration = recorder.snapshot.duration
                    try? self.store.save(self.jobs[index])
                    if recorder.snapshot.duration >= self.store.maximumDuration { self.stopMicrophone() }
                }
                if let player = self.player { self.position = max(0, player.currentTime().seconds); self.playing = player.rate > 0 }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func update(_ job: MediaJob) {
        let previous = jobs.first { $0.id == job.id }
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        do { try store.save(job) } catch { self.error = error.localizedDescription }
        if previous?.transcript != job.transcript || previous?.stage != job.stage { onTranscriptUpdate?(job) }
    }
    func select(_ id: String) { player?.pause(); player = nil; playing = false; position = 0; selectedID = id }
    func addAIDemo(_ job: MediaJob) throws {
        guard job.syntheticFixture, job.notebookID == "synthetic", job.transcript == SyntheticAIFixture.segments, try SafeWorkspace(root: store.root, originalRoot: store.originalRoot).readNote(job.targetNote) == SyntheticAIFixture.note else { throw MediaError.invalid("Demo inventada inválida.") }
        try store.save(job); jobs.insert(job, at: 0); select(job.id)
    }
    func tags(date: Date, units: String, exams: String, mode: InputMode) {
        guard var job = selected else { return }
        job.classDate = date; job.inputMode = mode; job.unitTags = split(units); job.examTags = split(exams); update(job)
    }
    private func split(_ text: String) -> [String] { Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
    func chooseImport(notebook: Notebook, note: String?) {
        guard !busy, !isRecording, let note else { error = "Abre una nota antes de importar."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Se conservará la fuente y se guardará una copia local para esta clase."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importMedia(source, notebook: notebook, note: note)
    }
    func importMedia(_ source: URL, notebook: Notebook, note: String) {
        guard !busy, !isRecording else { return }
        var job = MediaJob(notebookID: notebook.id, subject: notebook.name, note: note, sourceName: source.lastPathComponent)
        job.whisperConfiguration = WhisperTranscriber(store: store).preferredConfiguration
        update(job); select(job.id); busy = true; error = nil
        worker = Task { [self] in
            let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() }; busy = false }
            do {
                let copied = try await store.copySource(source, into: job) { [weak self, id = job.id] value in
                    await self?.copyProgress(id, value: value)
                }
                job.sourceRelativePath = copied.path; job.sourceDigest = copied.hash; job.sourceCopyComplete = true
                if let duplicate = jobs.first(where: { $0.id != job.id && $0.sourceDigest == copied.hash && $0.audioRelativePath != nil }) {
                    job.duplicateOf = duplicate.id; job.audioRelativePath = duplicate.audioRelativePath; job.duration = duplicate.duration
                    if WhisperConfiguration.canReuseTranscript(from: duplicate, for: job) {
                        job.transcript = duplicate.transcript; job.completedChunks = duplicate.completedChunks
                        job.asrQualityWarning = duplicate.asrQualityWarning
                        job.stage = duplicate.stage == .transcribed ? .transcribed : .ready
                    } else { job.stage = .ready }
                    job.progress = 1; update(job)
                    // Keep the separately dated import's source copy; references
                    // remain durable if other session records are later removed.
                } else { try await prepare(job) }
            } catch { failed(job.id, error: error) }
        }
    }
    private func copyProgress(_ id: String, value: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = value
    }
    private func prepare(_ value: MediaJob) async throws {
        var job = value; job.stage = .extracting; job.progress = 0; update(job)
        let prepared = try await store.prepareAudio(for: job) { [weak self, id = job.id] value in await self?.copyProgress(id, value: value) }
        job.audioRelativePath = prepared.path; job.duration = prepared.duration; job.stage = .ready; job.progress = 1; job.error = nil; update(job)
    }
    func resume() {
        if selected?.live != nil { resumeLive(); return }
        guard !busy, !isRecording, let job = selected else { return }
        if job.completedChunks > 0, job.audioRelativePath != nil { transcribe(); return }
        guard job.sourceCopyComplete else { error = "Copia incompleta. Vuelve a importar la fuente original; no se ha guardado acceso persistente a ella."; return }
        busy = true; worker = Task { [self] in
            defer { busy = false }
            do { try await prepare(job) } catch { failed(job.id, error: error) }
        }
    }
    func cancel() { worker?.cancel(); liveWorker?.cancel() }
    private func failed(_ id: String, error: Error) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.stage = error is CancellationError || worker?.isCancelled == true ? .cancelled : .failed
        job.error = job.stage == .cancelled ? "Cancelado; la copia completa y los fragmentos terminados se conservan." : error.localizedDescription
        update(job); self.error = job.error
    }
    /// Called exclusively by the user's Start button. No startup, test or
    /// automatic recovery path requests microphone access or starts capture.
    func startMicrophone(notebook: Notebook, note: String?) {
        guard !busy, !isRecording, let note else { error = "Abre una nota antes de grabar."; return }
        busy = true
        worker = Task { [self] in
            defer { busy = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "El permiso del micrófono no está concedido. Puedes importar un archivo o cambiarlo en Ajustes del Sistema."; return }
            guard !Task.isCancelled else { return }
            do {
                var job = MediaJob(notebookID: notebook.id, subject: notebook.name, note: note, sourceName: "Micrófono", microphone: true)
                job.whisperConfiguration = WhisperTranscriber(store: store).preferredConfiguration
                let rolling = try RollingPCMRecorder(store: store, job: job)
                let stream = MicrophoneStream(recorder: rolling, changed: { [weak self, id = job.id] state in
                    Task { @MainActor in self?.captureChanged(id, state: state) }
                }, failure: { [weak self] reason in
                    Task { @MainActor in self?.error = reason; self?.stopMicrophone() }
                })
                job.sourceRelativePath = rolling.sourcePath; job.live = LiveRecordingMetadata()
                do { try stream.start() } catch { _ = try? rolling.finish(); throw error }
                self.recorder = stream; recordingID = job.id; isRecording = true; error = nil; update(job); select(job.id)
                if whisperAvailable { startLive(job.id) }

            } catch { self.error = error.localizedDescription }
        }
    }
    private func captureChanged(_ id: String, state: LiveCaptureManifest) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.duration = state.duration
        job.live?.sealedChunks = state.chunks.count; job.live?.captureEnded = state.closed
        update(job)
    }
    private func refreshBusy() { busy = hashing || (liveWorker != nil && !isRecording) }
    func stopMicrophone() {
        guard let stream = recorder, let id = recordingID, var job = jobs.first(where: { $0.id == id }) else { return }
        do {
            let state = try stream.stop()
            job.duration = state.duration; job.audioRelativePath = state.source; job.sourceCopyComplete = true
            job.live?.sealedChunks = state.chunks.count; job.live?.captureEnded = true
            job.stage = liveWorker != nil ? .transcribing : (whisperAvailable ? .interrupted : .ready)
            update(job)
        } catch { self.error = error.localizedDescription; job.stage = .interrupted; job.error = error.localizedDescription; update(job) }
        recorder = nil; recordingID = nil; isRecording = false
        hashing = true; refreshBusy()
        worker = Task { [self] in
            defer { hashing = false; refreshBusy() }
            do {
                let store = self.store; let source = job.sourceRelativePath
                let digest = try await Task.detached { try source.map { try store.fingerprint($0) } }.value
                if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].sourceDigest = digest; try store.save(jobs[index]) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func shutdown() {
        worker?.cancel(); liveWorker?.cancel(); player?.pause()
        if let stream = recorder, let id = recordingID, var job = jobs.first(where: { $0.id == id }) {
            do {
                let state = try stream.stop(); job.duration = state.duration; job.audioRelativePath = state.source; job.sourceCopyComplete = true
                job.live?.captureEnded = true; job.live?.sealedChunks = state.chunks.count
            } catch { job.error = error.localizedDescription }
            job.stage = .interrupted; update(job)
        }
        recorder = nil; recordingID = nil; isRecording = false; timer?.cancel()
    }
    private func startLive(_ id: String) {
        guard liveWorker == nil else { return }
        liveWorker = Task { [self] in
            defer { liveWorker = nil; refreshBusy() }
            do {
                while !Task.isCancelled {
                    guard var job = jobs.first(where: { $0.id == id }) else { return }
                    let state: LiveCaptureManifest
                    if recordingID == id, let recorder { state = recorder.snapshot }
                    else { state = try RollingPCMRecorder.load(store: store, job: job) }
                    guard job.completedChunks >= 0, job.completedChunks <= state.chunks.count else { throw MediaError.invalid("Checkpoint en directo inválido.") }
                    let pending = Array(state.chunks.dropFirst(job.completedChunks).prefix(RollingPCMRecorder.maximumPendingInference))
                    if pending.isEmpty {
                        if state.closed {
                            job.stage = .transcribed; job.progress = 1; job.live?.captureEnded = true; job.live?.sealedChunks = state.chunks.count
                            update(job); return
                        }
                        try await Task.sleep(for: .milliseconds(250)); continue
                    }
                    for chunk in pending {
                        try Task.checkCancellation()
                        let segments = try await WhisperTranscriber(store: store).transcribeLiveChunk(chunk, job: job)
                        guard var current = jobs.first(where: { $0.id == id }) else { return }
                        if let warning = ASRQuality.repetitionWarning(segments) { current.asrQualityWarning = warning; current.error = warning; self.error = warning }
                        current.transcript = TranscriptMerge.append(segments, to: current.transcript)
                        current.completedChunks = chunk.index + 1; current.live?.processedChunks = chunk.index + 1
                        let sealed = max(state.chunks.count, current.live?.sealedChunks ?? 0)
                        current.live?.sealedChunks = sealed
                        current.progress = state.closed ? Double(chunk.index + 1) / Double(max(1, state.chunks.count)) : 0
                        update(current)
                        // Full source audio and raw Whisper JSON persist. Generated
                        // processed clips can be reconstructed from the full WAV.
                        try? store.removeTemporary(chunk.path)
                    }
                }
                throw CancellationError()
            } catch {
                if var current = jobs.first(where: { $0.id == id }) {
                    current.stage = isRecording ? .recording : (Task.isCancelled ? .cancelled : .failed)
                    current.error = "Transcripción en directo pausada: " + error.localizedDescription
                    update(current); self.error = current.error
                }
            }
        }
        refreshBusy()
    }
    private func resumeLive() {
        guard !busy, !isRecording, let original = selected, original.live != nil else { return }
        busy = true
        worker = Task { [self] in
            defer { refreshBusy() }
            do {
                let store = self.store
                let state = try await Task.detached { try RollingPCMRecorder.recover(store: store, job: original) }.value
                try Task.checkCancellation()
                guard var job = jobs.first(where: { $0.id == original.id }) else { return }
                job.audioRelativePath = state.source; job.sourceRelativePath = state.source; job.sourceCopyComplete = true
                job.duration = state.duration; job.live?.captureEnded = true; job.live?.sealedChunks = state.chunks.count
                job.stage = .transcribing; job.error = nil; update(job)
                startLive(job.id)
            } catch { failed(original.id, error: error) }
        }
    }
    func transcribe() {
        if selected?.live != nil { resumeLive(); return }
        guard !busy, !isRecording, var job = selected, job.audioRelativePath != nil else { return }
        if job.whisperConfiguration == nil, job.completedChunks == 0 {
            job.whisperConfiguration = WhisperTranscriber(store: store).preferredConfiguration
        }
        job.stage = .transcribing; job.error = nil; update(job); busy = true; error = nil
        worker = Task { [self] in
            defer { busy = false }
            do { _ = try await WhisperTranscriber(store: store).transcribe(job) { [weak self] value in await self?.update(value) } }
            catch { failed(job.id, error: error) }
        }
    }
    func editSegment(_ id: String, text: String) {
        guard !busy, !isRecording, var job = selected, let index = job.transcript.firstIndex(where: { $0.id == id }) else { return }
        job.transcript[index].text = text; update(job)
    }
    func playPause() {
        guard !isRecording, let audio = selected?.audioRelativePath else { return }
        do {
            if player == nil { player = AVPlayer(url: try store.url(audio)) }
            if player?.rate == 0 { player?.play(); playing = true } else { player?.pause(); playing = false }
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ seconds: Double) {
        do {
            if player == nil, let audio = selected?.audioRelativePath { player = AVPlayer(url: try store.url(audio)) }
            player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)); position = max(0, seconds)
        } catch { self.error = error.localizedDescription }
    }
}
