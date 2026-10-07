import Foundation
@preconcurrency import AVFoundation

/// Serial streaming resampler, usable without a microphone or audio engine.
/// End-of-stream drains the resampler tail before the saved WAV is finalized.
final class PCMStreamConverter {
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    let inputFormat: AVAudioFormat
    private let append: (Data) throws -> Void
    private var ended = false
    init(format: AVAudioFormat, append: @escaping (Data) throws -> Void) throws {
        guard format.sampleRate >= 8_000, format.sampleRate <= 192_000, format.channelCount > 0, format.channelCount <= 8,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: output) else { throw MediaError.invalid("Formato de captura no compatible.") }
        inputFormat = format; outputFormat = output; self.converter = converter; self.append = append
    }
    func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard !ended, buffer.frameLength > 0, buffer.frameLength <= 8192, buffer.format == inputFormat else { throw MediaError.invalid("Fragmento del conversor inválido.") }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw MediaError.invalid("No se pudo reservar audio.") }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard error == nil, status != .error else { throw error ?? MediaError.invalid("Error al convertir audio.") }
        try write(output)
    }
    func finish() throws {
        guard !ended else { return }; ended = true
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { throw MediaError.invalid("No se pudo cerrar el audio.") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            guard error == nil, status != .error else { throw error ?? MediaError.invalid("Error al cerrar el conversor.") }
            try write(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        throw MediaError.invalid("El conversor no terminó dentro del límite.")
    }
    private func write(_ output: AVAudioPCMBuffer) throws {
        if output.frameLength > 0, let pointer = output.int16ChannelData?[0] { try append(Data(bytes: pointer, count: Int(output.frameLength) * 2)) }
    }
}
