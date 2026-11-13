// A bounded, visual-only history of the microphone meter. No audio samples,
// speech recognition, or noise-floor decisions belong in the renderer.
import Foundation

struct AudioRibbon {
    static let sampleCount = 90
    static let sampleInterval = 1.0 / 30
    private var samples = Array(repeating: 0.0, count: sampleCount)
    private var next = 0
    private var remainder = 0.0
    private(set) var level = 0.0
    var isQuiet: Bool { level == 0 && samples.allSatisfy { $0 == 0 } }

    mutating func reset() { self = AudioRibbon() }

    /// Called only while microphone buffers are arriving. Freeze on interruption
    /// or pause; a quiet, connected microphone advances the history with zeros.
    mutating func advance(target: Double, delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        // Never replay a long main-thread stall as a burst of invented activity.
        let dt = min(delta, 0.1)
        let input = target.isFinite ? min(1, max(0, target)) : 0
        let energy = pow(max(0, (input - 0.035) / 0.965), 0.75)
        // Fast attack follows syllables; a short release softens their edges.
        let rate = energy > level ? 30.0 : 12.0
        level += (energy - level) * (1 - exp(-dt * rate))
        if level < 0.001 { level = 0 }
        remainder += dt
        while remainder >= Self.sampleInterval {
            samples[next] = level
            next = (next + 1) % Self.sampleCount
            remainder -= Self.sampleInterval
        }
    }

    /// Oldest at the left, newest at the right. Cubic interpolation makes a
    /// continuous ribbon from the existing meter instead of sharp meter bars.
    func amplitude(at position: Double) -> Double {
        guard position.isFinite else { return 0 }
        let x = min(1, max(0, position)) * Double(Self.sampleCount - 2)
            + remainder / Self.sampleInterval
        let index = Int(x)
        let t = x - Double(index)
        func sample(_ i: Int) -> Double {
            samples[(next + min(Self.sampleCount - 1, max(0, i))) % Self.sampleCount]
        }
        let a = sample(index - 1), b = sample(index)
        let c = sample(index + 1), d = sample(index + 2)
        let curve = 0.5 * ((2 * b) + (-a + c) * t
            + (2 * a - 5 * b + 4 * c - d) * t * t
            + (-a + 3 * b - 3 * c + d) * t * t * t)
        return min(1, max(0, curve))
    }
}
