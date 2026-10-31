import AppKit
import AVFoundation

/// A soft tick and a trackpad haptic each time the wheel's highlight moves, and a sound when a job ends.
/// With the Pumpkin colour the sounds turn spooky: a hollow creak, a ghostly "wooo" and a low groan.
/// Every sound is synthesized at launch, so no sound files ship with the app.
@MainActor
final class Feedback {
    static let shared = Feedback()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private let tickBuffer: AVAudioPCMBuffer
    private let creakBuffer: AVAudioPCMBuffer
    private let ghostBuffer: AVAudioPCMBuffer
    private let groanBuffer: AVAudioPCMBuffer
    private var lastTick = Date.distantPast

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        tickBuffer = Self.makeTick(format: format)
        creakBuffer = Self.makeCreak(format: format)
        ghostBuffer = Self.makeGhost(format: format)
        groanBuffer = Self.makeGroan(format: format)
        // A few players take turns so quick sweeps overlap instead of cutting each other off.
        for _ in 0..<6 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        engine.mainMixerNode.outputVolume = 0.35
    }

    func tick() {
        guard Preferences.shared.playSounds else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        // Keep very fast sweeps crisp rather than buzzing.
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.02 else { return }
        lastTick = now
        play(Palette.current.isSpooky ? creakBuffer : tickBuffer)
    }

    /// A job finished well.
    func done() {
        guard Preferences.shared.playSounds else { return }
        if Palette.current.isSpooky { play(ghostBuffer) } else { NSSound(named: "Glass")?.play() }
    }

    /// A job failed.
    func failed() {
        guard Preferences.shared.playSounds else { return }
        if Palette.current.isSpooky { play(groanBuffer) } else { NSSound.beep() }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        // The engine stops when the output device changes; restart on demand.
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer)
        player.play()
    }

    /// Fills a buffer of `seconds` from `sample(t)` and normalises it to `level`.
    private static func render(_ format: AVAudioFormat, seconds: Double, level: Double = 0.4,
                               _ sample: (Double) -> Double) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        var peak = 1e-9
        for i in 0..<Int(frames) {
            let value = sample(Double(i) / rate)
            samples[i] = Float(value)
            peak = max(peak, abs(value))
        }
        for i in 0..<Int(frames) { samples[i] = Float(Double(samples[i]) / peak * level) }
        return buffer
    }

    /// 140 ms hollow creak: a low knock whose pitch sags like an old floorboard, with a rasp on top.
    private static func makeCreak(format: AVAudioFormat) -> AVAudioPCMBuffer {
        var phase = 0.0, last = 0.0
        return render(format, seconds: 0.14, level: 0.36) { t in
            let frequency = 210 - 70 * min(t / 0.12, 1)
            phase += 2 * .pi * frequency / format.sampleRate
            let body = (sin(phase) + 0.35 * sin(2.02 * phase) + 0.18 * sin(3.1 * phase)) * exp(-t / 0.045)
            // A pulse train a few times a cycle reads as wood rubbing on wood.
            let rasp = 0.25 * (sin(phase * 7) > 0.92 ? 1 : 0) * exp(-t / 0.03)
            last = 0.7 * last + 0.3 * (body + rasp)
            return last * min(1, t / 0.002)
        }
    }

    /// 1.6 s ghost: a breathy "wooo" that swoops up and falls away, wavering, with two fading echoes.
    private static func makeGhost(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let seconds = 1.6, voiceLength = 1.05
        // The voice first, then the echoes laid over it.
        var voice = [Double](repeating: 0, count: Int(rate * seconds))
        var phase = 0.0
        for i in 0..<Int(rate * voiceLength) {
            let t = Double(i) / rate, x = t / voiceLength
            let glide = x < 0.35 ? 300 + 220 * (x / 0.35) : 520 - 170 * ((x - 0.35) / 0.65)
            let frequency = glide * (1 + 0.025 * sin(2 * .pi * 5.5 * t))
            phase += 2 * .pi * frequency / rate
            let envelope = min(1, t / 0.22) * min(1, (voiceLength - t) / 0.35)
            voice[i] = (sin(phase) + 0.22 * sin(2 * phase) + 0.08 * sin(3 * phase)) * envelope
        }
        var mixed = voice
        for (delay, gain) in [(0.19, 0.38), (0.38, 0.16)] {
            let offset = Int(rate * delay)
            for i in 0..<(voice.count - offset) { mixed[i + offset] += gain * voice[i] }
        }
        return render(format, seconds: seconds, level: 0.32) { t in mixed[min(Int(t * rate), mixed.count - 1)] }
    }

    /// 0.7 s groan: a low, rough voice sliding down, for a job that didn't work.
    private static func makeGroan(format: AVAudioFormat) -> AVAudioPCMBuffer {
        var phase = 0.0
        return render(format, seconds: 0.7, level: 0.38) { t in
            let frequency = 150 - 60 * (t / 0.7) + 4 * sin(2 * .pi * 7 * t)
            phase += 2 * .pi * frequency / format.sampleRate
            // A few harmonics give the throatiness; a slow swell and fade keeps it from clicking.
            let voice = sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase) + 0.15 * sin(5 * phase)
            return voice * min(1, t / 0.08) * min(1, (0.7 - t) / 0.25)
        }
    }

    /// 60 ms detent click: a bright edge that is gone within a millisecond, a short knock under it and a
    /// soft low thump carrying the tail. Crisp rather than tonal, so fast sweeps sound like a dial turning.
    private static func makeTick(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.06)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        func wave(_ frequency: Double, _ t: Double) -> Double { sin(2 * .pi * frequency * t) }
        var peak = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let edge = (wave(9_200, t) + 0.45 * wave(14_800, t) + 0.35 * wave(6_300, t)) * exp(-t / 0.000_45)
            let knock = 0.24 * wave(1_100, t) * exp(-t / 0.000_8)
            let thump = 0.09 * wave(230, t) * exp(-t / 0.005_2) * (1 - exp(-t / 0.000_6))
            let value = (edge + knock) * min(1, t / 0.000_2) + thump
            samples[i] = Float(value)
            peak = max(peak, abs(value))
        }
        // Normalise so the mixer's volume alone sets loudness.
        for i in 0..<Int(frames) { samples[i] = Float(Double(samples[i]) / peak * 0.4) }
        return buffer
    }
}
