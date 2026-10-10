import Foundation
@preconcurrency import AVFoundation

private final class OwnedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ source: AVAudioPCMBuffer) throws {
        guard source.frameLength > 0, source.frameLength <= 8192, source.format.channelCount <= 8,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { throw MediaError.invalid("Buffer del micrófono inválido.") }
        copy.frameLength = source.frameLength
        let inputs = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let outputs = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard inputs.count == outputs.count else { throw MediaError.invalid("Canales del micrófono inválidos.") }
        for index in inputs.indices {
            guard let input = inputs[index].mData, let output = outputs[index].mData, inputs[index].mDataByteSize <= outputs[index].mDataByteSize else { throw MediaError.invalid("Tamaño de audio inválido.") }
            memcpy(output, input, Int(inputs[index].mDataByteSize))
        }
        buffer = copy
    }
}

/// Device access occurs only in start(), after the app's user-triggered OS
/// permission gate. Eight copied buffers bound the tap queue; overflow stops
/// capture visibly instead of silently dropping lecturer speech.
public final class MicrophoneStream: @unchecked Sendable {
    public let recorder: RollingPCMRecorder
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "notes.microphone.pcm", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 8)
    private let lock = NSLock()
    private var active = false
    private var failed = false
    private var converter: PCMStreamConverter?
    private let changed: @Sendable (LiveCaptureManifest) -> Void
    private let failure: @Sendable (String) -> Void
    private let silence: SilenceLimit?
    private let quiet: @Sendable () -> Void
    private var reportedQuiet = false
    /// Seconds without speech after which `quiet` is called once: the speaker finished, or never began.
    public struct SilenceLimit: Sendable {
        public var afterSpeech: Double
        public var withoutSpeech: Double
        public init(afterSpeech: Double = 2.5, withoutSpeech: Double = 10) { self.afterSpeech = afterSpeech; self.withoutSpeech = withoutSpeech }
        public func reached(heard: Bool, silent: Double) -> Bool { silent >= (heard ? afterSpeech : withoutSpeech) }
    }
    public init(recorder: RollingPCMRecorder, silence: SilenceLimit? = nil, changed: @escaping @Sendable (LiveCaptureManifest) -> Void, failure: @escaping @Sendable (String) -> Void, quiet: @escaping @Sendable () -> Void = { }) {
        self.recorder = recorder; self.silence = silence; self.changed = changed; self.failure = failure; self.quiet = quiet
    }
    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = try PCMStreamConverter(format: format) { [recorder] data in try recorder.appendPCM16(data) }
        lock.lock(); active = true; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.enqueue(buffer) }
        do { engine.prepare(); try engine.start() }
        catch { input.removeTap(onBus: 0); lock.lock(); active = false; lock.unlock(); throw error }
    }
    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let accepts = active && !failed; lock.unlock()
        guard accepts else { return }
        guard slots.wait(timeout: .now()) == .success else { fail("La cola de captura se saturó. Se detiene el micrófono; revisa el último fragmento guardado."); return }
        do {
            let owned = try OwnedAudioBuffer(buffer)
            queue.async { [self, owned] in
                defer { slots.signal() }
                do { try consume(owned.buffer) } catch { fail(error.localizedDescription) }
            }
        } catch { slots.signal(); fail(error.localizedDescription) }
    }
    private func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard let converter else { throw MediaError.invalid("Conversor de micrófono no disponible.") }
        let before = recorder.snapshot.chunks.count
        try converter.consume(buffer)
        let snapshot = recorder.snapshot
        if snapshot.chunks.count != before { changed(snapshot) }
        if let silence, !reportedQuiet, let voice = recorder.voice, silence.reached(heard: voice.heard, silent: voice.silent) { reportedQuiet = true; quiet() }
    }
    private func fail(_ message: String) {
        lock.lock(); let first = !failed; failed = true; lock.unlock()
        if first { failure(message) }
    }
    @discardableResult public func stop() throws -> LiveCaptureManifest {
        lock.lock(); let wasActive = active; active = false; lock.unlock()
        if wasActive { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        return try queue.sync {
            do { if !recorder.snapshot.closed { try converter?.finish() } }
            catch { _ = try? recorder.finish(); throw error }
            return try recorder.finish()
        }
    }
    public var snapshot: LiveCaptureManifest { recorder.snapshot }
}
