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
    @Published var transcriptionProvider: TranscriptionProvider = TranscriptionProvider(rawValue: UserDefaults.standard.string(forKey: "transcription.provider") ?? "local") ?? .local {
        didSet { UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcription.provider") }
    }
    @Published var transcriptionModel: WhisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "transcription.model") ?? "small") ?? .small {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcription.model") }
    }
    @Published var transcriptionLanguage = UserDefaults.standard.string(forKey: "transcription.language") ?? "es" {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "transcription.language") }
    }
    @Published var captureMode: InputMode = InputMode(rawValue: UserDefaults.standard.string(forKey: "transcription.captureMode") ?? "") ?? .lecture {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "transcription.captureMode") }
    }
    @Published var modelOperation: String?
    /// The model being downloaded and how far along it is.
    @Published var modelDownload: (model: WhisperModel, progress: DownloadProgress)?
    @Published var useGPU = UserDefaults.standard.object(forKey: "transcription.gpu") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useGPU, forKey: "transcription.gpu") }
    }
    @Published var stopOnSilence = UserDefaults.standard.object(forKey: "transcription.stopOnSilence") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stopOnSilence, forKey: "transcription.stopOnSilence") }
    }
    @Published var modelError: String?
    @Published var installedModels: Set<WhisperModel> = []
    @Published var runtimeInstalled = false
    @Published var hasAPIKey = false
    @Published var teacherVoiceInstalled = false
    private var modelWorker: Task<Void, Never>?
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
        available(for: selected)
    }
    func available(for job: MediaJob?) -> Bool {
        let provider = job?.transcriptionProvider ?? (job == nil ? transcriptionProvider : .local)
        if provider == .openAI { return hasAPIKey }
        let configuration = job.flatMap { whisperConfiguration(for: $0) } ?? WhisperConfiguration(model: transcriptionModel)
        return WhisperTranscriber(store: store).available(for: configuration)
    }
    func refreshTranscription() {
        teacherVoiceInstalled = TeacherVoiceMatcher(store: store).available
        let transcriber = WhisperTranscriber(store: store)
        installedModels = Set(WhisperModel.allCases.filter { FileManager.default.fileExists(atPath: transcriber.model(for: WhisperConfiguration(model: $0)).path) })
        runtimeInstalled = FileManager.default.isExecutableFile(atPath: transcriber.binary.path)
        hasAPIKey = ((try? TranscriptionKeychain.read()) ?? "").isEmpty == false
    }
    func manageModel(_ model: WhisperModel?, remove: Bool = false) {
        guard !busy, !isRecording, modelWorker == nil else { return }
        modelOperation = remove ? "Eliminando…" : model == nil ? "Preparando Whisper v1.8.2…" : "Descargando y verificando modelo…"
        modelError = nil
        modelWorker = Task { [self] in
            defer { modelOperation = nil; modelDownload = nil; modelWorker = nil; refreshTranscription() }
            do {
                let installer = TranscriptionModelInstaller(root: store.root)
                if let model {
                    if remove { try installer.uninstall(model) }
                    else { try await installer.install(model) { [weak self] progress in Task { @MainActor in if self?.modelWorker != nil { self?.modelDownload = (model, progress) } } } }
                }
                else { try await installer.installRuntime() }
            } catch { modelError = Task.isCancelled ? "Instalación cancelada. El modelo anterior se conserva." : error.localizedDescription }
        }
    }
    func manageTeacherVoice(remove: Bool = false) {
        guard !busy, !isRecording, modelWorker == nil else { return }
        modelOperation = remove ? "Eliminando…" : "Instalando comparación de voz…"
        modelError = nil
        modelWorker = Task { [self] in
            defer { modelOperation = nil; modelWorker = nil; refreshTranscription() }
            do {
                let installer = TranscriptionModelInstaller(root: store.root)
                if remove { try installer.uninstallTeacherVoice() } else { try await installer.installTeacherVoice() }
            } catch { modelError = error.localizedDescription }
        }
    }
    func setTeacherReference(at start: Double) {
        guard !busy, modelOperation == nil, let original = selected else { return }
        busy = true
        worker = Task { [self] in
            defer { busy = false }
            var temporary: String?
            do {
                let matcher = TeacherVoiceMatcher(store: store)
                let reference = try matcher.reference(for: original, at: start)
                temporary = reference.path
                _ = try await matcher.annotate([], audio: store.url(reference.path), offset: 0, reference: reference)
                guard var job = jobs.first(where: { $0.id == original.id }) else { return }
                job.teacherReference = reference
                for index in job.transcript.indices { job.transcript[index].teacherSimilarity = nil }
                update(job); temporary = nil
            } catch { self.error = error.localizedDescription }
            if let temporary { try? store.removeTemporary(temporary) }
        }
    }
    func clearTeacherReference() {
        guard !busy, !isRecording, var job = selected else { return }
        job.teacherReference = nil
        for index in job.transcript.indices { job.transcript[index].teacherSimilarity = nil }
        update(job)
    }
    func compareTeacher() {
        guard !busy, !isRecording, modelOperation == nil, let original = selected, let reference = original.teacherReference, let source = original.audioRelativePath else { return }
        busy = true
        worker = Task { [self] in
            defer { busy = false }
            do {
                var job = original
                // Bound decoded audio and inference memory to one minute.
                for start in stride(from: 0.0, to: job.duration, by: 60) {
                    try Task.checkCancellation()
                    let indices = job.transcript.indices.filter { job.transcript[$0].start >= start && job.transcript[$0].start < start + 60 }
                    if indices.isEmpty { continue }
                    let end = min(job.duration, max(start + 60, indices.map { job.transcript[$0].end }.max() ?? start + 60))
                    let wav = try store.destination(for: job, name: "voice-review-\(UUID().uuidString).wav")
                    defer { try? store.removeTemporary(wav.relative) }
                    let store = self.store
                    try await Task.detached(priority: .utility) { try WhisperTranscriber.convertPCM(source: store.url(source), output: wav.url, offset: start, duration: min(302, end - start)) }.value
                    let results = try await TeacherVoiceMatcher(store: store).annotate(indices.map { job.transcript[$0] }, audio: wav.url, offset: start, reference: reference)
                    for (index, result) in zip(indices, results) { job.transcript[index] = result }
                    update(job)
                }
            } catch { self.error = error is CancellationError ? "Comparación cancelada; se conservan los resultados terminados." : error.localizedDescription }
        }
    }
    func retryTranscription() {
        guard !busy, !isRecording, modelOperation == nil, let old = selected, old.audioRelativePath != nil else { return }
        var job = MediaJob(notebookID: old.notebookID, subject: old.subject, note: old.targetNote, sourceName: old.sourceName)
        job.sourceRelativePath = old.sourceRelativePath; job.audioRelativePath = old.audioRelativePath
        job.sourceDigest = old.sourceDigest; job.sourceCopyComplete = old.sourceCopyComplete
        job.duration = old.duration; job.classDate = old.classDate; job.inputMode = old.inputMode
        job.unitTags = old.unitTags; job.examTags = old.examTags; job.teacherReference = old.teacherReference
        job.stage = .ready; configure(&job); update(job); select(job.id)
    }
    func cancelModelOperation() { modelWorker?.cancel() }
    private func configure(_ job: inout MediaJob) {
        job.transcriptionProvider = transcriptionProvider
        job.transcriptionLanguage = transcriptionLanguage
        job.whisperConfiguration = WhisperConfiguration(model: transcriptionModel)
        job.whisperConfiguration?.useGPU = useGPU
    }
    func useCurrentTranscriptionSettings() {
        guard !busy, !isRecording, var job = selected, job.completedChunks == 0 else { return }
        configure(&job); update(job)
    }
    init(workspace: SafeWorkspace) throws {
        store = LocalMediaStore(workspace: workspace); jobs = try store.recoverJobs(); selectedID = jobs.first?.id
        if UserDefaults.standard.string(forKey: "transcription.model") == nil {
            transcriptionModel = WhisperTranscriber(store: store).preferredConfiguration.model
        }
        refreshTranscription()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let recorder = self.recorder, let id = self.recordingID, let index = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[index].duration = recorder.snapshot.duration
                    try? self.store.save(self.jobs[index])
                    if recorder.snapshot.duration >= self.store.maximumDuration { self.stopMicrophone() }
                }
                if let player = self.player {
                    let next = max(0, player.currentTime().seconds)
                    if next.isFinite, abs(self.position - next) > 0.05 { self.position = next }
                    let active = player.rate > 0
                    if self.playing != active { self.playing = active }
                }
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
    func tags(date: Date, units: String, exams: String, mode: InputMode) {
        guard var job = selected else { return }
        job.classDate = date; job.inputMode = mode; job.unitTags = split(units); job.examTags = split(exams); update(job)
    }
    private func split(_ text: String) -> [String] { Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
    var createNotebookTarget: ((Notebook) throws -> String)?

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
    func startMicrophone(notebook: Notebook, note: String?, dictationID: String? = nil) {
        guard !busy, !isRecording, modelOperation == nil else { return }
        guard available(for: nil) else { error = "Configura el modelo local o la clave API en Preferencias → Dictado antes de grabar."; return }
        busy = true
        worker = Task { [self] in
            defer { busy = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "El permiso del micrófono no está concedido. Puedes cambiarlo en Ajustes del Sistema."; return }
            guard !Task.isCancelled else { return }
            do {
                // No note is created until the capture device actually starts.
                var job = MediaJob(notebookID: notebook.id, subject: notebook.name, note: note ?? "", sourceName: "Micrófono", microphone: true)
                configure(&job)
                if let dictationID { job.id = dictationID }
                job.inputMode = .dictation
                job.liveChunkSeconds = 5; job.liveVoiceSegments = true
                let rolling = try RollingPCMRecorder(store: store, job: job)
                let stream = MicrophoneStream(recorder: rolling, silence: stopOnSilence ? .init() : nil, changed: { [weak self, id = job.id] state in
                    Task { @MainActor in self?.captureChanged(id, state: state) }
                }, failure: { [weak self] reason in
                    Task { @MainActor in self?.error = reason; self?.stopMicrophone() }
                }, quiet: { [weak self, id = job.id] in
                    Task { @MainActor in if self?.recordingID == id { self?.stopMicrophone() } }
                })
                job.sourceRelativePath = rolling.sourcePath; job.live = LiveRecordingMetadata()
                do {
                    try stream.start()
                    if note == nil {
                        guard let target = try createNotebookTarget?(notebook) else { throw MediaError.invalid("Crea una nota antes de grabar.") }
                        job.targetNote = target
                    }
                } catch { _ = try? stream.stop(); _ = try? rolling.finish(); throw error }
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
        worker?.cancel(); liveWorker?.cancel(); modelWorker?.cancel(); player?.pause()
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
                        try await Task.sleep(for: .milliseconds(100)); continue
                    }
                    for chunk in pending {
                        try Task.checkCancellation()
                        var segments = try await WhisperTranscriber(store: store).transcribeLiveChunk(chunk, job: job)
                        if let reference = jobs.first(where: { $0.id == id })?.teacherReference {
                            segments = try await TeacherVoiceMatcher(store: store).annotate(segments, audio: store.url(chunk.path), offset: chunk.start, reference: reference)
                        }
                        guard var current = jobs.first(where: { $0.id == id }) else { return }
                        if let warning = ASRQuality.repetitionWarning(segments) { current.asrQualityWarning = warning; current.error = warning; self.error = warning }
                        current.transcript = TranscriptMerge.append(segments, to: current.transcript)
                        if let warning = ASRQuality.repetitionWarning(current.transcript) { current.asrQualityWarning = warning; current.error = warning }
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
        guard !busy, !isRecording, modelOperation == nil, let original = selected, available(for: original), original.live != nil else { return }
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
        guard !busy, !isRecording, modelOperation == nil, var job = selected, available(for: job), job.audioRelativePath != nil else { return }
        if job.whisperConfiguration == nil, job.completedChunks == 0 {
            job.whisperConfiguration = WhisperTranscriber(store: store).preferredConfiguration
            job.whisperConfiguration?.useGPU = useGPU
        }
        job.stage = .transcribing; job.error = nil
        let seconds = (try? WhisperConfiguration.resolved(for: job).importChunkSeconds) ?? 30
        job.progress = Double(job.completedChunks) / max(1, ceil(job.duration / seconds))
        update(job); busy = true; error = nil
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
