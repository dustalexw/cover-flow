import Accelerate
import Foundation

enum VisualizerStyle: Int, CaseIterable, Identifiable {
    case pulse, aurora, spectrum, nebula
    var id: Int { rawValue }
    var title: String { ["Pulse", "Aurora", "Spectrum", "Nebula"][rawValue] }
}

/// Analyses only the visualizer's copy of the PCM; playback gain is never changed.
/// Stereo power is combined after the FFT so out-of-phase recordings still react.
final class VisualizerSignal {
    static let bandCount = 64
    static let waveCount = 512
    static let fftSize = 2048
    private let transform = vDSP.DFT(count: VisualizerSignal.fftSize, direction: .forward,
                                    transformType: .complexComplex, ofType: Float.self)!
    private let window = (0..<VisualizerSignal.fftSize).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(VisualizerSignal.fftSize)) }
    private var left = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var right = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var real = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private let imaginary = [Float](repeating: 0, count: VisualizerSignal.fftSize)
    private var position = 0
    private var gain: Float = 1
    private var lastEnergy: Float = 0
    private var quietTime: Double = 0
    private var wasPlaying = false
    private(set) var bands = [Float](repeating: 0, count: bandCount)
    private(set) var wave = [Float](repeating: 0, count: waveCount)
    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var treble: Float = 0
    private(set) var level: Float = 0
    private(set) var onset: Float = 0

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
        let lSpectrum = spectrum(left)
        let rSpectrum = spectrum(right)
        let magnitude = (0..<Self.fftSize / 2).map { index in
            sqrt((lSpectrum.real[index] * lSpectrum.real[index] + lSpectrum.imaginary[index] * lSpectrum.imaginary[index]
                + rSpectrum.real[index] * rSpectrum.real[index] + rSpectrum.imaginary[index] * rSpectrum.imaginary[index]) * 0.5)
                * (4 / Float(Self.fftSize)) * scale
        }
        var targets = [Float](repeating: 0, count: Self.bandCount)
        for band in targets.indices {
            let low = max(1, Int(Self.frequency(band) * Double(Self.fftSize) / 48_000))
            let high = min(magnitude.count, max(low + 1, Int(Self.frequency(band + 1) * Double(Self.fftSize) / 48_000)))
            let peak = low < high ? magnitude[low..<high].max() ?? 0 : 0
            // A fixed dB floor keeps true silence dark while preserving quiet detail.
            targets[band] = audible * min(1, max(0, (20 * log10(max(0.00001, peak)) + 66) / 60))
            bands[band] = approach(bands[band], targets[band], dt, attack: 0.012, release: 0.18)
        }
        bass = envelope(bass, targets, 35...220, dt)
        mid = envelope(mid, targets, 220...2_500, dt)
        treble = envelope(treble, targets, 2_500...16_000, dt)
        level = approach(level, min(1, rms * scale * 3), dt, attack: 0.01, release: 0.2)
        let energy = targets.reduce(0, +) / Float(targets.count)
        onset = approach(onset, min(1, max(0, energy - lastEnergy) * 6), dt, attack: 0.006, release: 0.12)
        lastEnergy = energy
        for i in wave.indices {
            let index = (position + Self.fftSize - Self.waveCount + i) % Self.fftSize
            // Use the stronger channel; summing stereo would cancel phase-inverted audio.
            let sample = abs(left[index]) >= abs(right[index]) ? left[index] : right[index]
            wave[i] = tanh(sample * scale * 1.8)
        }
    }

    static func frequency(_ boundary: Int) -> Double { 30 * pow(600, Double(boundary) / Double(bandCount)) }
    private func finite(_ value: Float) -> Float { value.isFinite ? min(1, max(-1, value)) : 0 }
    private func approach(_ old: Float, _ target: Float, _ dt: Double, attack: Double, release: Double) -> Float {
        old + (target - old) * Float(1 - exp(-dt / (target > old ? attack : release)))
    }
    private func spectrum(_ values: [Float]) -> (real: [Float], imaginary: [Float]) {
        for i in real.indices { real[i] = values[(position + i) % Self.fftSize] * window[i] }
        let result = transform.transform(inputReal: real, inputImaginary: imaginary)
        return (result.real, result.imaginary)
    }
    private func envelope(_ old: Float, _ targets: [Float], _ range: ClosedRange<Double>, _ dt: Double) -> Float {
        let values = targets.indices.filter { range.contains(Self.frequency($0)) }.map { targets[$0] }
        return approach(old, values.max() ?? 0, dt, attack: 0.012, release: 0.16)
    }
    private func resetHistory() {
        left = Array(repeating: 0, count: Self.fftSize); right = left
        position = 0; gain = 1; lastEnergy = 0
    }
    private func decay(_ dt: Double) {
        let factor = Float(exp(-dt / 0.12))
        bands = bands.map { $0 * factor }; wave = wave.map { $0 * factor }
        bass *= factor; mid *= factor; treble *= factor; level *= factor; onset *= factor
        lastEnergy *= factor
    }
}
