import Accelerate
import Foundation

enum VisualizerStyle: Int, CaseIterable, Identifiable {
    case pulse, aurora, spectrum, nebula
    /// Psychedelic: a mirrored fractal mandala, and melting, swirling liquid colour.
    case kaleidoscope, liquid
    /// Spacey: a jump to hyperspace, and a spiral galaxy.
    case hyperspace, galaxy
    var id: Int { rawValue }
    var title: String {
        ["Pulse", "Aurora", "Spectrum", "Nebula", "Kaleidoscope", "Liquid", "Hyperspace", "Galaxy"][rawValue]
    }
}

/// Analyses only the visualizer's copy of the PCM; playback gain is never changed.
/// Stereo power is combined after the FFT so out-of-phase recordings still react.
/// Everything is preallocated: one update per display frame does no allocation.
final class VisualizerSignal {
    static let bandCount = 64
    static let waveCount = 512
    static let fftSize = 2048
    private let transform = vDSP.DFT(count: VisualizerSignal.fftSize, direction: .forward,
                                    transformType: .complexComplex, ofType: Float.self)!
    private let window = (0..<VisualizerSignal.fftSize).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(VisualizerSignal.fftSize)) }
    /// FFT bins each band covers, and the bands in each envelope range, worked out once.
    private static let bandBins: [Range<Int>] = (0..<bandCount).map { band in
        let low = max(1, Int(frequency(band) * Double(fftSize) / 48_000))
        let high = min(fftSize / 2, max(low + 1, Int(frequency(band + 1) * Double(fftSize) / 48_000)))
        return low..<max(low, high)
    }
    private static func bands(in range: ClosedRange<Double>) -> [Int] { (0..<bandCount).filter { range.contains(frequency($0)) } }
    private static let bassBands = bands(in: 35...220)
    private static let midBands = bands(in: 220...2_500)
    private static let trebleBands = bands(in: 2_500...16_000)
    private var left = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var right = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var real = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private let imaginary = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var leftReal = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var leftImaginary = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var rightReal = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var rightImaginary = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var magnitude = [Float](repeating: 0, count: VisualizerSignal.fftSize / 2)
    private var targets = [Float](repeating: 0, count: VisualizerSignal.bandCount)
    private var previousTargets = [Float](repeating: 0, count: VisualizerSignal.bandCount)
    private var fluxMean: Float = 0
    private var fluxVariance: Float = 0
    private var sinceBeat: Double = 1
    private var position = 0
    private var gain: Float = 1
    private var lastEnergy: Float = 0
    private var quietTime: Double = 0
    private var wasPlaying = false
    private var hasWave = false
    private(set) var bands = [Float](repeating: 0, count: bandCount)
    private(set) var wave = [Float](repeating: 0, count: waveCount)
    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var treble: Float = 0
    private(set) var level: Float = 0
    private(set) var onset: Float = 0
    /// 1 on each detected beat (a kick or strong low-end attack), then decays in ~0.2 s.
    private(set) var beat: Float = 0
    /// Beats so far; lets visuals change colour or direction on every hit.
    private(set) var beatCount = 0
    /// How fast the spectrum is changing right now (spectral flux), 0…1.
    private(set) var flux: Float = 0

    func update(_ samples: UnsafeBufferPointer<Float>, frames: Int, elapsed: Double,
                playing: Bool, response: Float = 1.25) {
        let dt = min(0.1, max(1.0 / 240, elapsed.isFinite ? elapsed : 1.0 / 60))
        let count = min(max(0, frames), samples.count / 2)
        if !playing && wasPlaying { resetHistory() }
        wasPlaying = playing
        guard playing, count > 0 else {
            quietTime += dt
            // A display frame can land between audio callbacks. Do not insert fake silence.
            if !playing || quietTime > 0.12 { decay(dt) }
            return
        }
        quietTime = 0
        var power: Float = 0
        for i in 0..<count {
            let l = finite(samples[i * 2]), r = finite(samples[i * 2 + 1])
            left[position] = l; right[position] = r
            position = (position + 1) % Self.fftSize
            power += (l * l + r * r) * 0.5
        }
        let rms = sqrt(power / Float(count))
        let sensitivity = response.isFinite ? min(2.5, max(0.5, response)) : 1.25
        let targetGain = min(6, max(1, 0.18 / max(0.025, rms)))
        gain = approach(gain, targetGain, dt, attack: 0.12, release: 0.5)
        let audible: Float = rms > 0.0003 ? 1 : 0
        let scale = gain * sensitivity * audible
        spectrum(left, real: &leftReal, imaginary: &leftImaginary)
        spectrum(right, real: &rightReal, imaginary: &rightImaginary)
        let normalization: Float = 4 / Float(Self.fftSize)
        for index in magnitude.indices {
            let lr = leftReal[index], li = leftImaginary[index]
            let rr = rightReal[index], ri = rightImaginary[index]
            let energy: Float = lr * lr + li * li + rr * rr + ri * ri
            magnitude[index] = sqrt(energy * 0.5) * normalization * scale
        }
        for band in targets.indices {
            let bins = Self.bandBins[band]
            var peak: Float = 0
            for bin in bins { peak = max(peak, magnitude[bin]) }
            // A fixed dB floor keeps true silence dark while preserving quiet detail.
            targets[band] = audible * min(1, max(0, (20 * log10(max(0.00001, peak)) + 66) / 60))
            bands[band] = approach(bands[band], targets[band], dt, attack: 0.008, release: 0.13)
        }
        detectBeat(dt)
        bass = envelope(bass, Self.bassBands, dt)
        mid = envelope(mid, Self.midBands, dt)
        treble = envelope(treble, Self.trebleBands, dt)
        level = approach(level, min(1, rms * scale * 3), dt, attack: 0.01, release: 0.2)
        var energy: Float = 0
        for value in targets { energy += value }
        energy /= Float(targets.count)
        onset = approach(onset, min(1, max(0, energy - lastEnergy) * 6), dt, attack: 0.006, release: 0.12)
        lastEnergy = energy
        updateWave(scale: scale, dt: dt)
    }

    /// Beats are moments when the low end rises much faster than it has been: spectral
    /// flux in the bass and low mids above an adaptive threshold (mean + 1.6 standard
    /// deviations of recent flux), at most about five a second.
    private func detectBeat(_ dt: Double) {
        var low: Float = 0, all: Float = 0
        for band in targets.indices {
            let rise = max(0, targets[band] - previousTargets[band])
            all += rise
            if band < Self.lowBandLimit { low += rise }
            previousTargets[band] = targets[band]
        }
        low /= Float(Self.lowBandLimit)
        all /= Float(targets.count)
        flux = approach(flux, min(1, all * 14), dt, attack: 0.01, release: 0.15)
        let k = Float(1 - exp(-dt / 0.6))
        let threshold = fluxMean + 1.6 * sqrt(max(0, fluxVariance))
        sinceBeat += dt
        if low > threshold && low > 0.02 && sinceBeat > 0.18 {
            beat = 1
            beatCount &+= 1
            sinceBeat = 0
        } else {
            beat *= Float(exp(-dt / 0.2))
        }
        let delta = low - fluxMean
        fluxMean += k * delta
        fluxVariance = (1 - k) * (fluxVariance + k * delta * delta)
    }
    /// Bands below ~250 Hz count toward beats.
    private static let lowBandLimit = (0..<bandCount).first { frequency($0) > 250 } ?? 16

    /// The waveform starts at a rising zero crossing, like an oscilloscope's trigger, so
    /// a steady tone holds still instead of sliding sideways every frame, and each
    /// point eases toward its new value over ~20 ms so it doesn't flicker.
    private func updateWave(scale: Float, dt: Double) {
        @inline(__always) func sample(_ index: Int) -> Float {
            let i = (index % Self.fftSize + Self.fftSize) % Self.fftSize
            // Use the stronger channel; summing stereo would cancel phase-inverted audio.
            return abs(left[i]) >= abs(right[i]) ? left[i] : right[i]
        }
        let latest = position + Self.fftSize - Self.waveCount       // newest possible start
        var start = latest
        for back in 1..<(Self.fftSize - Self.waveCount) {
            let i = latest - back
            if sample(i - 1) < 0 && sample(i) >= 0 { start = i; break }
        }
        let ease = hasWave ? Float(1 - exp(-dt / 0.02)) : 1
        for i in wave.indices {
            let target = tanh(sample(start + i) * scale * 1.8)
            wave[i] += (target - wave[i]) * ease
        }
        hasWave = true
    }

    static func frequency(_ boundary: Int) -> Double { 30 * pow(600, Double(boundary) / Double(bandCount)) }
    private func finite(_ value: Float) -> Float { value.isFinite ? min(1, max(-1, value)) : 0 }
    private func approach(_ old: Float, _ target: Float, _ dt: Double, attack: Double, release: Double) -> Float {
        old + (target - old) * Float(1 - exp(-dt / (target > old ? attack : release)))
    }
    private func spectrum(_ values: [Float], real outReal: inout [Float], imaginary outImaginary: inout [Float]) {
        for i in real.indices { real[i] = values[(position + i) % Self.fftSize] * window[i] }
        transform.transform(inputReal: real, inputImaginary: imaginary, outputReal: &outReal, outputImaginary: &outImaginary)
    }
    private func envelope(_ old: Float, _ indices: [Int], _ dt: Double) -> Float {
        var peak: Float = 0
        for index in indices { peak = max(peak, targets[index]) }
        return approach(old, peak, dt, attack: 0.012, release: 0.16)
    }
    private func resetHistory() {
        for i in left.indices { left[i] = 0; right[i] = 0 }
        position = 0; gain = 1; lastEnergy = 0; hasWave = false
        for i in previousTargets.indices { previousTargets[i] = 0 }
        fluxMean = 0; fluxVariance = 0; sinceBeat = 1
    }
    private func decay(_ dt: Double) {
        let factor = Float(exp(-dt / 0.12))
        for i in bands.indices { bands[i] *= factor }
        for i in wave.indices { wave[i] *= factor }
        bass *= factor; mid *= factor; treble *= factor; level *= factor; onset *= factor
        beat *= factor; flux *= factor
        lastEnergy *= factor
    }
}
