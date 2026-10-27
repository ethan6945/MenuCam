import Foundation

/// Uniform overall enhancement for the microphone path (no voice detection).
///
/// Every input is lifted by the same gain, so anything audible in the room is
/// recorded — a quiet aside, a distant remark, a soft mechanical sound. There
/// is **no speech detector and no noise gate**: gain is never muted just
/// because the input looks like "silence" or "not speech".
///
/// The gain tracks the overall loudness of the last few seconds so the result
/// stays stable instead of clipping, but it applies one rule to everything:
///
/// - gain = target / overall level, clamped to `maxGain`
/// - ~2.5 s to come up, ~0.6 s to come down (slow both ways = no pumping)
/// - one smooth per-buffer peak guard, so nothing clips
///
/// Because the boost is uniform, the room's own noise floor rises with the
/// signal — that is the intended trade for catching very quiet sound.
///
/// Signal path: boost -> +4 dB presence peak at 3.2 kHz -> peak guard. There is
/// deliberately no high-pass here any more: low frequencies carry a lot of the
/// energy of a distant or muffled voice, and the previous 90 Hz low cut was in
/// practice attenuating the whole speech band (measured -23.6 dB at 1 kHz), so
/// it worked against the goal of picking up quiet room sound.
///
/// Stateful; call `process` sequentially on one thread (the capture queue).
struct SpeechEnhancer {
    var currentGain: Float { gain }
    private var gain: Float = 1.0
    private let sampleRate: Double
    private var envelope: Float = 0.02
    // RBJ peaking EQ, 3.2 kHz, +4 dB, Q = 1.2
    private var pkX1: Float = 0
    private var pkX2: Float = 0
    private var pkY1: Float = 0
    private var pkY2: Float = 0
    private let pkB0: Float
    private let pkB1: Float
    private let pkB2: Float
    private let pkA1: Float
    private let pkA2: Float

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let fs = sampleRate
        let f0 = 3200.0
        let q = 1.2
        let db = 4.0
        let a = pow(10, db / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let b0 = 1 + alpha * a
        let b1 = -2 * cos(w0)
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cos(w0)
        let a2 = 1 - alpha / a
        pkB0 = Float(b0 / a0)
        pkB1 = Float(b1 / a0)
        pkB2 = Float(b2 / a0)
        pkA1 = Float(a1 / a0)
        pkA2 = Float(a2 / a0)
    }

    mutating func process(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let n = Float(samples.count)
        var sum: Float = 0
        for s in samples { sum += s * s }
        let level = (sum / n).squareRoot()

        // Track the overall level slowly in both directions: quiet passages
        // keep their lift, loud passages do not pump. No gate anywhere.
        let upPerBuffer = Double(samples.count) / sampleRate / 2.5      // ~2.5 s up
        let downPerBuffer = Double(samples.count) / sampleRate / 0.6    // ~0.6 s down
        let up = Float(1 - exp(-upPerBuffer))
        let down = Float(1 - exp(-downPerBuffer))
        envelope += (level - envelope) * (level > envelope ? up : down)

        // One uniform rule for every input: lift the overall level towards the
        // target. No speech/silence branching and no "below floor" exception —
        // however quiet the room is, everything present is brought up together.
        let target: Float = 0.12        // ~-18.5 dBFS overall target
        let maxGain: Float = 256        // +48 dB ceiling for practical silence
        let desired = min(maxGain, max(1, target / max(envelope, 0.0001)))
        let alpha: Float = 0.25
        gain = gain + (desired - gain) * alpha
        for i in samples.indices {
            let amplified = samples[i] * gain
            let pk = pkB0 * amplified + pkB1 * pkX1 + pkB2 * pkX2 - pkA1 * pkY1 - pkA2 * pkY2
            pkX2 = pkX1
            pkX1 = amplified
            pkY2 = pkY1
            pkY1 = pk
            samples[i] = pk
        }

        // Single smooth peak guard: if the boosted buffer would clip, scale the
        // whole buffer down slightly instead of hard-clipping samples. Uniform,
        // per-buffer, no distortion artefacts.
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        if peak > 0.98 {
            let correction = 0.98 / peak
            for i in samples.indices { samples[i] *= correction }
        }
    }
}
