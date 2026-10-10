import Foundation

/// Bounded constant gain per inference chunk. Preserves timing, dynamics and
/// the original recording; this is level adjustment, not noise removal.
public enum SpeechAudioLevel {
    public static func gain(rms: Double, peak: Double) -> Double {
        guard rms.isFinite, peak.isFinite, rms >= 0.0001, peak > 0 else { return 1 }
        // Aim for roughly -24 dBFS RMS, with at most +18 dB gain and -1 dBFS peak.
        return max(1, min(7.943282347, 0.063095734 / rms, 0.891250938 / peak))
    }
    public static func normalize(_ samples: UnsafeMutableBufferPointer<Int16>) {
        guard !samples.isEmpty else { return }
        var sum = 0.0, peak = 0.0
        for sample in samples {
            let x = Double(sample) / 32768
            sum += x * x; peak = max(peak, abs(x))
        }
        let scale = gain(rms: sqrt(sum / Double(samples.count)), peak: peak)
        guard scale > 1 else { return }
        for index in samples.indices {
            samples[index] = Int16(clamping: Int((Double(samples[index]) * scale).rounded()))
        }
    }
}
