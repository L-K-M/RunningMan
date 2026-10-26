import AVFoundation
import RunningManCore

/// Small synthesized sounds for lap events, rendered once and played quietly. Nothing is
/// bundled: every sound is a few hundred samples of sine, noise and envelope.
///
/// Everything but `play` runs on `queue`: starting the audio engine can take most of a second,
/// which on the main thread would stall the very animation the sound accompanies.
final class LapSounds: @unchecked Sendable {
    static let shared = LapSounds()

    private let queue = DispatchQueue(label: "ch.lkmc.RunningMan.lap-sounds", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var isRunning = false
    private var idleStop: DispatchWorkItem?

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.55
    }

    func play(_ event: LapEvent) {
        let name: String
        switch event {
        case .split(let seconds, let personalBest):
            // Faster splits tick higher; a personal best rings a fifth above.
            name = personalBest ? "best" : seconds < -LapProgress.splitThreshold ? "fast" : seconds > LapProgress.splitThreshold ? "slow" : "even"
        case .overtake: name = "overtake"
        case .finished(let outcome):
            switch outcome {
            case .success: name = "finish"
            case .failure: name = "fall"
            case .cancelled, .running: return
            }
        }
        queue.async { self.start(name) }
    }

    private func start(_ name: String) {
        guard let buffer = buffer(named: name) else { return }
        do {
            if !isRunning { try engine.start(); isRunning = true }
        } catch { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
        // Release the audio device a little after the last sound.
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            guard let self else { return }
            player.stop(); engine.stop(); isRunning = false
        }
        idleStop = stop
        queue.asyncAfter(deadline: .now() + 4, execute: stop)
    }

    private func buffer(named name: String) -> AVAudioPCMBuffer? {
        if let cached = buffers[name] { return cached }
        let samples: [Float]
        switch name {
        case "fast": samples = Self.woodBlock(frequency: 1_320, level: 0.30)
        case "even": samples = Self.woodBlock(frequency: 1_046, level: 0.24)
        case "slow": samples = Self.woodBlock(frequency: 784, level: 0.24)
        case "best": samples = Self.mix(Self.woodBlock(frequency: 1_320, level: 0.28), Self.bell(frequency: 1_976, duration: 0.45, level: 0.16, delay: 0.05))
        case "overtake": samples = Self.whoosh(duration: 0.34, level: 0.22)
        case "finish": samples = Self.mix(Self.bell(frequency: 659, duration: 0.6, level: 0.18, delay: 0),
                                          Self.bell(frequency: 784, duration: 0.6, level: 0.18, delay: 0.09),
                                          Self.bell(frequency: 1_046, duration: 0.9, level: 0.20, delay: 0.18))
        case "fall": samples = Self.thud(level: 0.4)
        default: return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        buffers[name] = buffer
        return buffer
    }

    // MARK: Synthesis

    private static let rate = 44_100.0

    /// A struck block: a sine with a fast exponential decay and a click of noise at the attack.
    private static func woodBlock(frequency: Double, level: Float) -> [Float] {
        let count = Int(rate * 0.09)
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { index in
            let t = Double(index) / rate
            let tone = sin(2 * .pi * frequency * t) + 0.35 * sin(2 * .pi * frequency * 2.76 * t)
            let click = t < 0.003 ? Double.random(in: -1...1, using: &generator) * (1 - t / 0.003) * 0.6 : 0
            return Float((tone * exp(-t * 55) + click) * 0.6) * level
        }
    }

    /// A soft bell partial with its first overtone, for chimes.
    private static func bell(frequency: Double, duration: Double, level: Float, delay: Double) -> [Float] {
        let count = Int(rate * (duration + delay))
        return (0..<count).map { index in
            let t = Double(index) / rate - delay
            guard t >= 0 else { return 0 }
            let attack = min(1, t / 0.006)
            let tone = sin(2 * .pi * frequency * t) + 0.25 * sin(2 * .pi * frequency * 2 * t)
            return Float(tone * attack * exp(-t * 4.5) * 0.8) * level
        }
    }

    /// Band-passed noise whose center sweeps up and back down: something passing close by.
    private static func whoosh(duration: Double, level: Float) -> [Float] {
        let count = Int(rate * duration)
        var generator = SystemRandomNumberGenerator()
        var low = 0.0, band = 0.0
        return (0..<count).map { index in
            let progress = Double(index) / Double(count)
            let center = 500 + 2_600 * sin(.pi * progress)
            let f = 2 * sin(.pi * center / rate)
            let input = Double.random(in: -1...1, using: &generator)
            // A state-variable filter: low and band outputs, fixed resonance.
            low += f * band
            let high = input - low - 0.7 * band
            band += f * high
            let envelope = sin(.pi * progress) * sin(.pi * progress)
            return Float(band * envelope * 0.9) * level
        }
    }

    /// A low, short drum: a pitch-dropping sine.
    private static func thud(level: Float) -> [Float] {
        let count = Int(rate * 0.22)
        var phase = 0.0
        return (0..<count).map { index in
            let t = Double(index) / rate
            phase += 2 * .pi * (110 - 55 * min(1, t / 0.12)) / rate
            return Float(sin(phase) * exp(-t * 18)) * level
        }
    }

    private static func mix(_ parts: [Float]...) -> [Float] {
        let length = parts.map(\.count).max() ?? 0
        return (0..<length).map { index in parts.reduce(0) { $0 + (index < $1.count ? $1[index] : 0) } }
    }
}
