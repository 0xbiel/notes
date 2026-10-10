import Foundation
import CryptoKit

/// A recording-scoped reference, never a global identity or a claim about
/// overlapping speakers. Unmatched and short spans remain unclassified.
public struct TeacherVoiceReference: Codable, Equatable, Sendable {
    public var path: String
    public var start: Double
    public var duration: Double
    public init(path: String, start: Double, duration: Double) {
        self.path = path; self.start = start; self.duration = duration
    }
}

public struct TeacherVoiceMatcher: Sendable {
    public let store: LocalMediaStore
    public init(store: LocalMediaStore) { self.store = store }
    public var directory: URL { store.root.appendingPathComponent("runtime/teacher-voice") }
    public var available: Bool {
        FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("venv/bin/python").path) && FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.onnx").path) && FileManager.default.fileExists(atPath: directory.appendingPathComponent("vad.onnx").path)
    }
    public func reference(for job: MediaJob, at start: Double) throws -> TeacherVoiceReference {
        guard start.isFinite, start >= 0, start + 5 <= job.duration, let source = job.audioRelativePath ?? job.sourceRelativePath else { throw MediaError.invalid("Elige al menos cinco segundos de voz del profesor en el audio preparado.") }
        let duration = min(8, job.duration - start)
        let target = try store.destination(for: job, name: "teacher-reference-\(UUID().uuidString).wav")
        if job.live != nil, job.audioRelativePath == nil {
            // A running capture has a changing WAV header. Read only the
            // already-written PCM bytes, leaving the writer and header alone.
            let reader = try FileHandle(forReadingFrom: store.url(source)); defer { try? reader.close() }
            try reader.seek(toOffset: 44 + UInt64(start * 16000) * 2)
            let expected = Int(duration * 16000) * 2
            guard let pcm = try reader.read(upToCount: expected), pcm.count == expected else { throw MediaError.invalid("Espera a que se guarden estos segundos de audio y vuelve a intentarlo.") }
            var data = RollingPCMRecorder.header(frames: UInt64(pcm.count / 2)); data.append(pcm)
            try data.write(to: target.url, options: .withoutOverwriting)
        } else {
            try WhisperTranscriber.convertPCM(source: store.url(source), output: target.url, offset: start, duration: duration)
        }
        return TeacherVoiceReference(path: target.relative, start: start, duration: duration)
    }
    public func annotate(_ segments: [MediaTranscriptSegment], audio: URL, offset: Double, reference: TeacherVoiceReference) async throws -> [MediaTranscriptSegment] {
        guard available else { throw MediaError.invalid("Instala Comparación de voz en Preferencias → Transcripción.") }
        struct Span: Encodable { let start: Double; let end: Double }
        let spans = segments.map { Span(start: max(0, $0.start - offset), end: max(0, $0.end - offset)) }
        let work = directory.appendingPathComponent("comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent("spans.json"), output = work.appendingPathComponent("scores.json")
        try JSONEncoder().encode(spans).write(to: input)
        let command = LocalProcess()
        command.process.executableURL = directory.appendingPathComponent("venv/bin/python")
        command.process.arguments = ["-c", Self.helper, directory.appendingPathComponent("model.onnx").path, try store.url(reference.path).path, audio.path, input.path, output.path]
        command.process.environment = ProcessInfo.processInfo.environment.merging(["OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1", "VECLIB_MAXIMUM_THREADS": "1"]) { _, new in new }
        command.process.standardOutput = FileHandle.nullDevice; command.process.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try command.run() }.value
            try Task.checkCancellation()
        } onCancel: { command.cancel() }
        struct Result: Decodable { let scores: [Double?]; let referenceValid: Bool }
        let result = try JSONDecoder().decode(Result.self, from: Data(contentsOf: output))
        guard result.referenceValid else { throw MediaError.invalid("No se detecta suficiente voz clara en la referencia. Escucha el audio y elige otro momento donde solo hable el profesor.") }
        let scores = result.scores
        guard scores.count == segments.count else { throw MediaError.invalid("Resultado de comparación de voz incompleto.") }
        return zip(segments, scores).map { segment, score in
            var result = segment
            result.teacherSimilarity = score.flatMap { $0.isFinite && (-1...1).contains($0) ? $0 : nil }
            return result
        }
    }
    // Read bounded windows, one inference thread. Compare several windows and
    // keep the lowest score rather than claiming a mixed turn is all teacher.
    static let helper = #"""
import json, sys, wave
from pathlib import Path
import numpy as np
import sherpa_onnx
model, reference, audio, spans, output = sys.argv[1:]
e = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=model, num_threads=1, provider="cpu"))
def read(path, start=0, end=8):
    with wave.open(path, "rb") as f:
        assert f.getframerate() == 16000 and f.getnchannels() == 1 and f.getsampwidth() == 2
        f.setpos(min(f.getnframes(), max(0, int(start*16000))))
        return np.frombuffer(f.readframes(max(0, int((end-start)*16000))), dtype="<i2").astype(np.float32) / 32768
def embed(x):
    if len(x) < 32000: return None
    rms = float(np.sqrt(np.mean(x*x)))
    peak = float(np.max(np.abs(x)))
    if rms < 0.0001 or peak == 0: return None
    x = x * max(1, min(8, 0.06/rms, 0.95/peak))
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = str(Path(model).with_name("vad.onnx"))
    config.silero_vad.threshold = 0.5
    config.sample_rate = 16000
    config.num_threads = 1
    vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=30)
    for a in range(0, len(x), 512): vad.accept_waveform(x[a:a+512])
    vad.flush()
    speech = []
    while not vad.empty():
        speech.extend(vad.front.samples); vad.pop()
    if len(speech) < max(24000, len(x)*0.5): return None
    x = np.asarray(speech, dtype=np.float32)
    s = e.create_stream(); s.accept_waveform(sample_rate=16000, waveform=x); s.input_finished()
    if not e.is_ready(s): return None
    v = np.array(e.compute(s)); n = np.linalg.norm(v)
    return v/n if n > 0 else None
ref = embed(read(reference))
if ref is None:
    with open(output, 'w') as f: json.dump({"scores": [], "referenceValid": False}, f)
    sys.exit(0)
result = []
for span in json.load(open(spans)):
    start, end = span['start'], span['end']
    scores = []
    for a in np.arange(start, end, 4):
        b = min(a+4, end)
        if b-a < 2: continue
        v = embed(read(audio, a, b))
        if v is None: scores = []; break
        scores.append(float(np.clip(ref @ v, -1, 1)))
    result.append(min(scores) if scores else None)
with open(output, 'w') as f: json.dump({'scores': result, 'referenceValid': True}, f, allow_nan=False)
"""#
}
