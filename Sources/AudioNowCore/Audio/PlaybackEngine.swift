import AVFoundation
import Foundation
import Synchronization

/// Everything the real-time render block touches, in one @unchecked
/// Sendable holder. Atomics are non-copyable, so they live here and are
/// reached through this single class reference — the only thing the
/// render block captures.
final class RenderState: @unchecked Sendable {
    let ring = PCMRingBuffer(seconds: 43)
    let gate = Atomic<Int>(0)          // 0 idle · 1 filling · 2 playing · 3 fading
    let eos = Atomic<Bool>(false)
    let fadeLeft = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)
    let played = Atomic<Int>(0)
    let prebuffer = Atomic<Int>(PlaybackEngine.frameSamples)
}

/// Pull-model playback: AVAudioSourceNode's render block reads from the
/// SPSC ring. Every requirement lives as atomics inside the render gate:
/// prebuffer = a fill state, underruns = an exact count, stop = a
/// sample-accurate fade, position = a counter. The real-time thread shares
/// no locks with anything (see docs/swift-design.md §A/Q1).
public final class PlaybackEngine: @unchecked Sendable {
    public static let sampleRate = 24_000
    public static let frameSamples = 3_200
    public static let fadeSamples = 1_200          // 50ms

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let state = RenderState()
    public var ring: PCMRingBuffer { state.ring }

    private let restartQueue = DispatchQueue(label: "audio-now.engine-restart")
    private var observer: NSObjectProtocol?

    public init() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Double(Self.sampleRate),
                                channels: 1, interleaved: false)!
        let state = self.state              // sole capture: atomics + ring
        let fadeLen = Self.fadeSamples

        source = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!
                .assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            memset(out, 0, n * 4)
            switch state.gate.load(ordering: .acquiring) {
            case 1 where state.ring.availableToRead
                    >= state.prebuffer.load(ordering: .relaxed)
                    || state.eos.load(ordering: .relaxed):
                state.gate.store(2, ordering: .releasing)
                fallthrough
            case 2:
                let got = state.ring.read(into: out, count: n)
                state.played.wrappingAdd(got, ordering: .relaxed)
                if got < n {
                    if state.eos.load(ordering: .relaxed)
                        && state.ring.availableToRead == 0 {
                        state.gate.store(0, ordering: .releasing)   // natural end
                    } else {
                        state.underruns.wrappingAdd(1, ordering: .relaxed)
                        state.gate.store(1, ordering: .releasing)   // rebuffer
                    }
                }
            case 3:
                let got = state.ring.read(into: out, count: n)
                var f = state.fadeLeft.load(ordering: .relaxed)
                for i in 0..<got {
                    out[i] *= Float(max(f, 0)) / Float(fadeLen)
                    f -= 1
                }
                state.fadeLeft.store(f, ordering: .relaxed)
                if f <= 0 || got == 0 {
                    state.ring.discardAllFromConsumer()
                    state.gate.store(0, ordering: .releasing)
                }
            default:
                break
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
        // The engine stops itself on default-device change / sleep-wake and
        // stays silent unless restarted (design pitfall #5).
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterDeviceChange()
        }
    }

    /// Opens the device (once); the engine then stays running for the
    /// daemon's lifetime, rendering silence between jobs.
    public func warm() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    public var isRunning: Bool { engine.isRunning }

    public func beginJob() {
        state.eos.store(false, ordering: .relaxed)
        state.gate.store(1, ordering: .releasing)
    }

    public func endOfStream() {
        state.eos.store(true, ordering: .releasing)
    }

    /// Sample-accurate fade to silence, <=50ms after the store.
    public func stopNow() {
        if !engine.isRunning || state.gate.load(ordering: .acquiring) <= 1 {
            state.ring.discardAllFromConsumer()
            state.gate.store(0, ordering: .releasing)
            return
        }
        state.fadeLeft.store(Self.fadeSamples, ordering: .relaxed)
        state.gate.store(3, ordering: .releasing)
    }

    /// Escape hatch when the device is gone and no render callback will
    /// ever run the gate back to idle.
    public func forceIdle() {
        state.ring.discardAllFromConsumer()
        state.gate.store(0, ordering: .releasing)
        state.eos.store(false, ordering: .relaxed)
    }

    public var isDrained: Bool { state.gate.load(ordering: .acquiring) == 0 }

    public var underrunCount: Int { state.underruns.load(ordering: .relaxed) }
    public var playedSamples: Int { state.played.load(ordering: .relaxed) }
    public var playedSeconds: Double {
        Double(playedSamples) / Double(Self.sampleRate)
    }

    /// Session-adaptive prebuffer: the daemon escalates to 2 frames if a
    /// job ever underruns (trade 133ms of TTFS for glitch-immunity).
    public func setPrebuffer(frames: Int) {
        state.prebuffer.store(max(1, frames) * Self.frameSamples,
                              ordering: .relaxed)
    }
    public var prebufferFrames: Int {
        state.prebuffer.load(ordering: .relaxed) / Self.frameSamples
    }

    private func restartAfterDeviceChange() {
        restartQueue.async { [weak self] in
            guard let self else { return }
            for attempt in 1...3 {
                do {
                    try self.engine.start()
                    Log.info("audio engine restarted after device change "
                             + "(attempt \(attempt))")
                    return
                } catch {
                    Log.warn("engine restart attempt \(attempt) failed: \(error)")
                    usleep(200_000)
                }
            }
            Log.error("audio device lost — playback unavailable; "
                      + "jobs continue writing wav files")
        }
    }
}
