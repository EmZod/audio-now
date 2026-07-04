# audio-now: Swift Architecture Design

*Produced by a dedicated architecture review during planning (2026-07-03). This is the
reference design for the Swift side; PLAN.md holds the system-level plan. Deviations
discovered during implementation should be noted at the bottom of this file.*

---

## A. Recommended Architecture and Rationale

**The one-sentence shape:** a single SwiftPM executable with a thin ArgumentParser CLI over a library core; the daemon is one control-plane actor surrounded by four dedicated data-plane execution contexts (network DispatchQueue, worker-stdout thread, worker-stderr thread, Core Audio's real-time thread), with the only hot path — PCM — flowing worker pipe → reader thread → lock-free ring buffer → `AVAudioSourceNode` render block, never touching the actor.

**Decisions at a glance (one per design question):**

| # | Question | Decision |
|---|----------|----------|
| 1 | Playback | `AVAudioEngine` + `AVAudioSourceNode` (pull-model render block) fed by a lock-free SPSC ring buffer. Not `AVAudioPlayerNode`, not AudioQueue. |
| 2 | Concurrency | One `Daemon` actor for all control state; DispatchQueue for sockets; raw `Thread` + blocking `read(2)` for worker pipes; atomics (`Synchronization.Atomic`) for everything the render thread touches. |
| 3 | Socket server | Raw POSIX `AF_UNIX` sockets + `DispatchSource` read/write sources on one serial "net" queue. No Network.framework, no NIO. |
| 4 | Daemonize | `posix_spawn` of own binary with `POSIX_SPAWN_SETSID`, stdio redirected via file actions. No double-fork, no launchd. `flock` on two files: `spawn.lock` (CLI, held seconds) and `daemon.pid` (daemon, held for life). |
| 5 | Worker | Foundation `Process` for the worker; dedicated thread with blocking `readFully` for the framed protocol; bounded ~30 s ring + *stop reading the pipe* as the backpressure mechanism; WAV streamed to disk incrementally, never held in RAM. |
| 6 | Protocol | NDJSON both directions on the socket; NDJSON in / `[type][len LE32][payload]` framed out for the worker. Full schema in section C. |
| 7 | Layout | Two targets (`audio` executable + `AudioNowCore` library) plus a `fakeworker` test executable and a test target. |
| 8 | Client disconnect | **Job keeps playing.** Agents are ephemeral; `audio stop` is the kill switch. |

### Why AVAudioSourceNode (Q1)

`AVAudioPlayerNode.scheduleBuffer` is the obvious choice and the wrong one for this system, for four structural reasons: (1) starvation is *silent* — when you fail to schedule in time there is no callback, no counter, nothing; you cannot meet the "detect/count underruns" requirement without heuristics. (2) `stop()` is immediate and clicks; a fade requires ramping mixer volume from a non-real-time thread on a timer, which is racy against the exact stop instant. (3) A 55-minute job is ~24,800 scheduled buffers with completion-handler churn and opaque internal queuing. (4) "How many samples have actually hit the device" is awkward to extract.

`AVAudioSourceNode` inverts the model: Core Audio's I/O thread *pulls* from your render block, and every requirement becomes a few atomic operations inside that block: prebuffer is a gate state (`filling` → render silence until ring ≥ 2 frames), underruns are an exact count (asked for N, ring had M < N), stop-with-fade is a per-sample gain ramp applied *on the render thread itself* (sample-accurate, click-free, silent within 50 ms of the atomic store — well under the 100 ms budget), and played-sample position is an atomic counter. Raw AudioUnit would give the same semantics with C-API pain; AudioQueue gives worse ergonomics and nothing extra. The source node is created with a 24 kHz mono float32 format and connected to `mainMixerNode`; **the engine performs the sample-rate conversion to the device rate for free** — no manual resampling.

Warm-across-jobs: the engine starts on the first job (or `warm`) and stays running for the daemon's lifetime, with the render block emitting silence in the `idle` state. Device open cost is paid exactly once. (If idle power ever matters: `engine.pause()` after ~2 min idle and `engine.start()` on next job is a <10 ms resume; not needed for v1 since the daemon self-terminates after an hour anyway.)

### Concurrency model (Q2)

Strict-concurrency roles, exhaustively:

- **`Daemon` actor** — the only place with mutable control state: FIFO job queue, active job, per-job watcher connections, worker lifecycle FSM, recent-results cache, idle timer, stats. The control lane is "free" because *nothing slow ever executes on the actor*: streaming happens on the reader thread and the render thread; the actor only receives small events and issues small commands. A `stop` during minute 40 of a 55-minute job is an actor hop (microseconds) + three atomic stores.
- **`netQueue` (serial DispatchQueue)** — owns the listen fd, all connection fds, their read/write DispatchSources, and their in/out byte buffers. Parsed NDJSON lines hop to the actor via `Task { await daemon.handle(...) }`. The actor never touches an fd; it holds `ConnectionHandle` values — `Sendable` structs whose `sendLine` closure dispatches back onto `netQueue`.
- **Worker stdout: one dedicated `Thread`** (`.userInitiated` QoS) doing blocking `readFully(2)` of the framed protocol. `'A'` frames: float32 samples go straight into the ring (one memcpy) and, converted, into the WAV file — *zero actor hops on the hot path*. `'J'` frames: decode, `Task` → actor. Job-scoped reader context (wav writer, playing/discard flags) lives in a small `@unchecked Sendable` holder: atomics for flags the render thread or actor flips, `Synchronization.Mutex` for the context swap (never touched by the render thread).
- **Worker stderr: second dedicated `Thread`**, pumps lines to the daemon log. Mandatory — an undrained stderr pipe wedges the worker.
- **Core Audio real-time thread** — the render block. Touches only the ring buffer and `Atomic<Int>`s. No locks, no allocation, no logging, no actor references captured. This is what makes priority inversion *structurally impossible*: the RT thread shares no lock with anyone.
- **Main thread** — parks in `dispatchMain()`; hosts signal DispatchSources and the `AVAudioEngineConfigurationChange` notification observer.

PCM copy count: kernel pipe → staging buffer (`read`) → ring (`memcpy`) → output `AudioBufferList` (`memcpy` in render) + staging → int16 conversion buffer → `write(2)` for the WAV. Two copies on the playback path; fine forever.

### Backpressure and long jobs (Q5)

At 1.3x realtime, a 55-minute job finishes generating ~13 minutes before playback ends — ~75 MB of float32 if buffered naively. Instead: the ring is bounded (~43 s, 4 MB). When it is full, **the reader thread simply stops reading** (50 ms sleep-poll loop, checking a discard flag). The 64 KB kernel pipe fills, the worker's stdout `write` blocks, and generation throttles to ~realtime with zero protocol machinery. The WAV is written incrementally as frames arrive (placeholder RIFF/data sizes, patched on finalize), so memory stays flat regardless of job length. `render` jobs never touch the ring, so they run at full generation speed. Consequences accepted: on a `say` job the WAV completes near playback completion, and worker progress events are delayed while reads are paused (they are progress-only; `stop` resumes reading with the discard flag set, so cancellation stays instant).

### Sockets (Q3) and daemonization (Q4)

Raw POSIX because the workload is trivial (< 10 connections, tiny messages) and `NWListener`'s unix-path support is genuinely awkward. `DispatchSource.makeReadSource` on the nonblocking listen fd drives an accept loop; each connection gets a read source, a line buffer, and an outbound buffer flushed with `write` until `EAGAIN`, at which point a write source takes over — the standard ~60-line pattern. `SO_NOSIGPIPE` on every fd; socket file `chmod 0600`, run dir `0700`.

Daemonization needs no double-fork on macOS: `posix_spawn` with `POSIX_SPAWN_SETSID` (+ `POSIX_SPAWN_CLOEXEC_DEFAULT`) detaches into a new session; file actions point stdin at `/dev/null` and stdout/stderr at `~/.audio-now/log/daemon.log` (append). The CLI never `waitpid`s; when the CLI exits the child reparents to launchd, which reaps it. Spawn race: CLI takes `flock(LOCK_EX)` on `spawn.lock`, re-probes the socket (the race loser finds the winner's daemon), spawns if still dead, polls the socket up to 10 s, releases. The daemon independently takes `flock(LOCK_EX|LOCK_NB)` on `daemon.pid` at startup — failure means a healthy daemon exists, exit 0; success proves any existing socket file is stale, so unlink-then-bind is always safe. SIGTERM/SIGINT via signal DispatchSources (after `signal(sig, SIG_IGN)`) → `daemon.shutdown()`: stop accepting, fade active job, `{"op":"shutdown"}` to worker then SIGTERM at +2 s then SIGKILL at +5 s, finalize WAV, notify clients, unlink socket, release pidfile, exit. Auto-spawn applies **only** to `say`, `render`, `warm`, `voices`; `stop`/`wait`/`status` report "daemon not running" rather than booting a 7B model to say nothing is happening.

---

## B. Module Layout (Q7)

```
audio-now/
├── Package.swift                     (~30)   targets: audio, AudioNowCore, fakeworker, tests
├── Sources/audio/                    — executable, thin
│   ├── Main.swift                    (~40)   @main root command, subcommand registry
│   ├── Commands.swift               (~260)   say/render/stop/wait/status/voices/warm → DaemonClient; flags; exit codes
│   └── DaemonCommand.swift          (~130)   daemon run|stop|logs; run wires DaemonCore together, dispatchMain()
├── Sources/AudioNowCore/
│   ├── Protocol/
│   │   ├── Messages.swift           (~220)   Codable: Request, ClientEvent, WorkerCommand, WorkerEvent; error codes
│   │   ├── Framing.swift             (~80)   worker frame header encode/decode + incremental parser (pure, testable)
│   │   └── NDJSON.swift              (~60)   line splitter, single-line JSONEncoder helpers
│   ├── Daemon/
│   │   ├── Daemon.swift             (~340)   THE actor: connection registry, watcher fan-out, worker FSM, shutdown
│   │   ├── JobQueue.swift           (~150)   pure value-type state machine: (state, input) → (state, [Effect]); no I/O
│   │   ├── SocketServer.swift       (~230)   listen/accept/Connection/ConnectionHandle (netQueue-confined)
│   │   ├── Worker.swift             (~250)   Process lifecycle, stdin NDJSON writer, restart backoff, kill escalation
│   │   ├── WorkerPipeReader.swift   (~190)   stdout thread (framing→ring/wav/events), stderr thread
│   │   └── IdleTimer.swift           (~60)   rearmable, generation-counted, injected Sleeper
│   ├── Audio/
│   │   ├── PlaybackEngine.swift     (~230)   engine + source node + gate FSM + fade + counters + config-change recovery
│   │   ├── PCMRingBuffer.swift      (~120)   lock-free SPSC, monotonic head/tail, Atomic<Int>
│   │   └── WavWriter.swift          (~130)   incremental 16-bit/f32 WAV, header patch on finalize, vDSP f32→s16
│   ├── Client/
│   │   ├── DaemonClient.swift       (~180)   blocking connect/send/stream-lines; auto-spawn-and-retry policy
│   │   └── Spawner.swift            (~130)   posix_spawn SETSID + file actions; flock spawn guard; socket poll
│   └── Support/
│       ├── Paths.swift               (~70)   ~/.audio-now layout (run/ log/ out/), mkdir 0700, sun_path length check
│       ├── FileLock.swift            (~60)   open+flock wrapper, pid write/read
│       └── Log.swift                 (~60)   timestamped leveled logger (file or stderr in --foreground)
├── Sources/fakeworker/Main.swift     (~90)   speaks the worker protocol, emits sine PCM at configurable pace/TTFA;
│                                             flags to crash/hang/ignore-cancel for failure drills
└── Tests/AudioNowCoreTests/         (~700 total)
    ├── FramingTests, NDJSONTests, MessagesRoundTripTests      — pure codecs
    ├── JobQueueTests                — enqueue/start/done/cancel/crash orderings against the pure FSM
    ├── IdleTimerTests               — injected manual Sleeper clock; rearm/cancel/stale-generation
    ├── PCMRingBufferTests           — 2-thread stress: no loss, no dup, bounded
    ├── WavWriterTests               — tmp files: header math, s16 conversion, partial-finalize
    └── IntegrationTests             — spawn fakeworker, run reader against real pipes (no audio device needed)
```

~2,700 LOC core + ~430 CLI. Two-target split because executable targets are second-class for `@testable import`; everything with logic lives in `AudioNowCore` with injected dependencies (Sleeper clock, worker command, paths). `PlaybackEngine` gets a hardware smoke test behind an env guard, skipped in CI; everything else needs no audio hardware.

---

## C. Protocol Schemas (Q6)

### CLI ↔ daemon (NDJSON over unix socket, one request line per connection, event lines back until terminal event)

Requests:

```json
{"cmd":"ping"}
{"cmd":"say","text":"...","voice":"maya","out":"/abs/path.wav","detach":false,"seed":42,"voices":{"0":"carter"},"extra":{}}
{"cmd":"render","text":"...","voice":"maya","out":"/abs/path.wav","format":"s16","seed":42,"voices":{"0":"carter"},"extra":{}}
{"cmd":"stop","scope":"all"}                       // "all" (default) | "current" | "job", +"job":"j-000042"
{"cmd":"wait","job":"j-000042"}                    // job omitted → wait until queue fully idle
{"cmd":"status"}
{"cmd":"voices"}
{"cmd":"warm"}
{"cmd":"shutdown"}                                 // used by `audio daemon stop`
```

`voice`, `voices`, `seed`, `out`, `extra` optional; `out` defaults to `~/.audio-now/out/<job>.wav` (a WAV is written for every job). `extra` is an opaque object passed through to the worker (forward compat). *(Deviation from original report: `speed` dropped — VibeVoice has no native rate control; `seed` and multi-speaker `voices` map added.)*

Events (each line has `"event"`; job-scoped ones carry `"job"`):

```json
{"event":"pong","proto":1,"version":"0.1.0","pid":4242}
{"event":"queued","job":"j-000042","position":2}
{"event":"started","job":"j-000042","voice":"maya"}
{"event":"ttfa","job":"j-000042","ms":642}                                  // request-accept → first PCM frame
{"event":"progress","job":"j-000042","generated_s":12.4,"played_s":10.1,"rtf":1.31}   // ~1 Hz
{"event":"done","job":"j-000042","reason":"completed","wav":"~/.audio-now/out/j-000042.wav",
 "duration_s":33.2,"underruns":0}                                           // reason: completed|stopped
{"event":"stopped","jobs":["j-000042"],"queue_cleared":2}
{"event":"idle"}                                                            // terminal for bare `wait`
{"event":"status","daemon":{"pid":4242,"uptime_s":532,"version":"0.1.0","idle_exit_in_s":3140},
 "worker":{"state":"ready","pid":4310},"engine":{"running":true,"underruns_total":0},
 "active":{"job":"j-000042","generated_s":12.4,"played_s":10.1},"queue":["j-000043"]}
{"event":"voices","voices":[{"id":"maya","name":"Maya","lang":"en"}]}
{"event":"ready","load_ms":8123,"was_warm":false}                           // terminal for warm
{"event":"error","job":"j-000042","code":"worker_crashed","message":"..."}
```

Error codes: `bad_request, unknown_job, worker_unavailable, worker_crashed, cancelled_shutdown, audio_device_lost, wav_write_failed, daemon_shutting_down`.

Semantics: job ids are daemon-monotonic (`j-` + counter). `say` streams events until `done`/`error` unless `detach:true` (terminal after `queued`; then use `wait`). **`wait` attach:** the daemon keeps `watchers: [JobID: [ConnectionHandle]]` and fans every job event out to owner + watchers; a `wait` for a finished job is answered instantly from a 32-entry recent-results cache; unknown id → `error unknown_job`. `done` for a `say` job is emitted only after the ring has *audibly drained* (render gate returned to idle), so `wait` means "speech finished," not "generation finished." Exit codes: `done`/`stopped`/`idle` → 0, `error` → 2.

### Daemon ↔ worker

Daemon → worker stdin, NDJSON (worker must drain stdin continuously and **exit on stdin EOF** — that is the orphan-cleanup mechanism):

```json
{"op":"generate","job":"j-000042","text":"...","voice":"maya","seed":42,"voices":{"0":"carter"},"extra":{}}
{"op":"cancel","job":"j-000042"}
{"op":"list_voices"}          // worker must answer BEFORE model load completes
{"op":"encode_voice","name":"maya","wav":"/abs/clip.wav"}
{"op":"shutdown"}
```

Worker → daemon stdout, binary framed: `[1 byte type][4 byte LE length][payload]`. Type `'J'`: UTF-8 JSON event. Type `'A'`: raw little-endian float32 mono 24 kHz samples for the *current* job (single active generation, bracketed by events, so no per-frame job id; max payload 64 KB enforced by the parser).

```json
{"event":"ready","model":"vibevoice-7b","load_ms":9000}
{"event":"voices","voices":[...]}
{"event":"started","job":"j-000042"}
{"event":"pcm_begin","job":"j-000042","sample_rate":24000,"channels":1,"format":"f32"}
{"event":"progress","job":"j-000042","generated_s":12.4,"rtf":1.29}
{"event":"done","job":"j-000042","generated_s":33.2}
{"event":"cancelled","job":"j-000042"}
{"event":"error","job":"j-000042","message":"..."}
{"event":"fatal","message":"..."}
```

The reader thread finalizes the WAV *before* forwarding `done`/`cancelled`/`error` to the actor, so when a client sees `done`, the file is sealed.

---

## D. Key Code Sketches

### D1. Ring buffer + playback engine

```swift
import AVFoundation
import Synchronization

/// SPSC lock-free ring. Producer: worker reader thread. Consumer: Core Audio RT thread.
/// Head/tail are monotonically increasing sample counts (no empty/full ambiguity).
final class PCMRingBuffer: @unchecked Sendable {
    private let capacity: Int, mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)   // producer-advanced
    private let tail = Atomic<Int>(0)   // consumer-advanced

    init(seconds: Double, sampleRate: Int = 24_000) {
        var cap = 1; while cap < Int(seconds * Double(sampleRate)) { cap <<= 1 }
        capacity = cap; mask = cap - 1
        storage = .allocate(capacity: cap); storage.initialize(repeating: 0, count: cap)
    }
    var availableToRead: Int { head.load(ordering: .acquiring) - tail.load(ordering: .relaxed) }
    var freeSpace: Int { capacity - (head.load(ordering: .relaxed) - tail.load(ordering: .acquiring)) }

    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {      // producer only
        guard freeSpace >= count else { return false }                  // caller sleep-polls → backpressure
        let h = head.load(ordering: .relaxed)
        let first = min(count, capacity - (h & mask))                   // two memcpys split at wrap
        memcpy(storage + (h & mask), src, first * 4)
        if count > first { memcpy(storage, src + first, (count - first) * 4) }
        head.store(h + count, ordering: .releasing); return true
    }
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {  // consumer (RT) only
        let t = tail.load(ordering: .relaxed)
        let n = min(count, head.load(ordering: .acquiring) - t)
        let first = min(n, capacity - (t & mask))
        memcpy(dst, storage + (t & mask), first * 4)
        if n > first { memcpy(dst + first, storage, (n - first) * 4) }
        tail.store(t + n, ordering: .releasing); return n
    }
    func discardAllFromConsumer() { tail.store(head.load(ordering: .acquiring), ordering: .releasing) }
}

/// Gate: 0 idle (warm silence)  1 filling (prebuffer)  2 playing  3 fading (stop)
final class PlaybackEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    let ring = PCMRingBuffer(seconds: 43)
    private let gate = Atomic<Int>(0), eos = Atomic<Bool>(false)
    private let fadeLeft = Atomic<Int>(0), underruns = Atomic<Int>(0), played = Atomic<Int>(0)
    private let prebuffer = 6_400                                  // 2 frames ≈ 266 ms (make adaptive: start 1)
    private let fadeLen = 1_200                                    // 50 ms @ 24 kHz

    init() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                channels: 1, interleaved: false)!
        // Capture ONLY @unchecked-Sendable atomic holders — never an actor, never self-with-state.
        source = AVAudioSourceNode(format: fmt) {
            [ring, gate, eos, fadeLeft, underruns, played, prebuffer, fadeLen]
            _, _, frameCount, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!
                        .assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            memset(out, 0, n * 4)                                  // default: silence (idle/filling)
            switch gate.load(ordering: .acquiring) {
            case 1 where ring.availableToRead >= prebuffer || eos.load(ordering: .relaxed):
                gate.store(2, ordering: .releasing); fallthrough
            case 2:
                let got = ring.read(into: out, count: n)
                played.wrappingAdd(got, ordering: .relaxed)
                if got < n {
                    if eos.load(ordering: .relaxed) && ring.availableToRead == 0 {
                        gate.store(0, ordering: .releasing)        // natural end; daemon polls gate==0
                    } else if got == 0 || !eos.load(ordering: .relaxed) {
                        underruns.wrappingAdd(1, ordering: .relaxed)
                        gate.store(1, ordering: .releasing)        // rebuffer instead of stuttering
                    }
                }
            case 3:                                                // stop: sample-accurate fade
                let got = ring.read(into: out, count: n)
                var f = fadeLeft.load(ordering: .relaxed)
                for i in 0..<got { out[i] *= Float(max(f, 0)) / Float(fadeLen); f -= 1 }
                fadeLeft.store(f, ordering: .relaxed)
                if f <= 0 || got == 0 { ring.discardAllFromConsumer(); gate.store(0, ordering: .releasing) }
            default: break
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)  // engine SRCs 24k → device rate
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterDeviceChange()                       // headphones unplug / sleep-wake
        }
    }
    func warm() throws { if !engine.isRunning { try engine.start() } }   // device opens once, stays open
    func beginJob() { eos.store(false, ordering: .relaxed); gate.store(1, ordering: .releasing) }
    func endOfStream() { eos.store(true, ordering: .releasing) }
    func stopNow() { fadeLeft.store(fadeLen, ordering: .relaxed); gate.store(3, ordering: .releasing) }
    var isDrained: Bool { gate.load(ordering: .acquiring) == 0 }         // daemon polls at 100 ms after eos
    var stats: (underruns: Int, playedSamples: Int) {
        (underruns.load(ordering: .relaxed), played.load(ordering: .relaxed))
    }
}
```

### D2. Worker pipe reader (framed protocol, backpressure, WAV tee)

```swift
final class JobIO: @unchecked Sendable {                    // swapped under a Mutex per job
    let wav: WavWriter?; let playback: Bool
    let discard = Atomic<Bool>(false)                        // set by daemon on stop
    init(wav: WavWriter?, playback: Bool) { self.wav = wav; self.playback = playback }
}

final class WorkerPipeReader: @unchecked Sendable {
    private let fd: Int32, ring: PCMRingBuffer
    private let ctx = Mutex<JobIO?>(nil)                     // Synchronization.Mutex; never on RT thread
    private let daemon: Daemon                               // actor; events hop via Task

    func start() {
        let t = Thread { [self] in run() }
        t.name = "worker-stdout"; t.qualityOfService = .userInitiated; t.start()
    }
    private func run() {
        var header = [UInt8](repeating: 0, count: 5)
        var payload = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            guard readFully(fd, &header, 5) else { break }   // EOF/error → worker gone
            let len = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16 | Int(header[4]) << 24
            guard len <= payload.count, readFully(fd, &payload, len) else { break }
            switch header[0] {
            case UInt8(ascii: "A"):
                let io = ctx.withLock { $0 }
                payload.withUnsafeBytes { raw in
                    let f = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                    let samples = len / 4
                    io?.wav?.append(f, count: samples)       // incremental disk write, this thread
                    guard let io, io.playback else { return }
                    while !io.discard.load(ordering: .relaxed),
                          !ring.write(f, count: samples) {
                        Thread.sleep(forTimeInterval: 0.05)  // ring full → stop reading → pipe fills
                    }                                        //  → worker's write blocks → GPU throttles
                }
            case UInt8(ascii: "J"):
                let data = Data(payload[0 ..< len])
                if let ev = try? JSONDecoder().decode(WorkerEvent.self, from: data) {
                    if ev.isTerminalForJob { ctx.withLock { $0?.wav?.finalize(); $0 = nil } }
                    Task { await daemon.workerEvent(ev) }    // WAV sealed BEFORE actor sees `done`
                }
            default:
                Task { await daemon.workerProtocolError() }; return
            }
        }
        Task { await daemon.workerPipeClosed() }             // deduped against terminationHandler
    }
}

func readFully(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
    var off = 0
    while off < n {
        let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
        if r <= 0 { if r < 0 && errno == EINTR { continue }; return false }
        off += r
    }
    return true
}
```

### D3. Socket server (POSIX + DispatchSource, no NIO)

```swift
final class SocketServer: @unchecked Sendable {              // all state confined to netQueue
    private let netQueue = DispatchQueue(label: "audio-now.net", qos: .userInitiated)
    private var listenFD: Int32 = -1, acceptSrc: DispatchSourceRead?
    private var conns: [UInt64: Connection] = [:]; private var nextID: UInt64 = 0
    let onLine: @Sendable (ConnectionHandle, String) -> Void  // → Task { await daemon.handle(...) }
    let onClose: @Sendable (UInt64) -> Void

    func start(path: String) throws {                         // caller holds daemon.pid flock
        guard path.utf8.count < 104 else { throw AudioNowError.socketPathTooLong(path) }
        unlink(path)                                          // lock proves any existing file is stale
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        try withUnsafePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                else { throw AudioNowError.bindFailed(errno) }
            }
        }
        chmod(path, 0o600); listen(listenFD, 16)
        _ = fcntl(listenFD, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: netQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume(); acceptSrc = src
    }
    private func acceptPending() {                            // netQueue
        while case let fd = accept(listenFD, nil, nil), fd >= 0 {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(4))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            nextID += 1
            conns[nextID] = Connection(id: nextID, fd: fd, queue: netQueue,
                                       onLine: onLine, onClosed: { [weak self] id in
                                           self?.conns[id] = nil; self?.onClose(id) })
        }
    }
}

/// Per-connection: read source → line buffer → onLine; send() → outBuf → write until EAGAIN
/// → write source resumes → flush → suspend. Close on EOF/EPIPE/ECONNRESET.
/// The Daemon actor only ever holds:
struct ConnectionHandle: Sendable {
    let id: UInt64
    let sendLine: @Sendable (String) -> Void   // netQueue.async { conn?.enqueue(line + "\n") }
}
```

### D4. Daemonize + spawn guard

```swift
enum Spawner {
    static func connectOrSpawn(autoSpawn: Bool) throws -> Int32 {
        if let fd = try? connectSocket() { return fd }
        guard autoSpawn else { throw AudioNowError.daemonNotRunning }   // stop/wait/status never spawn
        let guardLock = try FileLock(Paths.spawnLock); try guardLock.lockExclusive(timeout: 12)
        defer { guardLock.unlock() }
        if let fd = try? connectSocket() { return fd }                  // lost the race: winner's daemon
        try spawnDetachedDaemon()
        for _ in 0 ..< 120 {                                            // poll ≤ 12 s (worker loads lazily)
            usleep(100_000)
            if let fd = try? connectSocket() { return fd }
        }
        throw AudioNowError.spawnTimeout(logHint: Paths.logFile)
    }
    static func spawnDetachedDaemon() throws {
        var buf = [CChar](repeating: 0, count: 4096); var size = UInt32(buf.count)
        _NSGetExecutablePath(&buf, &size)
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, Paths.logFile, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var pid: pid_t = 0
        let argv = makeCArgv([String(cString: buf), "daemon", "run"])   // strdup'd, freed after
        guard posix_spawn(&pid, buf, &fa, &attr, argv, environ) == 0
        else { throw AudioNowError.spawnFailed(errno) }
        // No waitpid: CLI exits shortly; child reparents to launchd, which reaps it.
    }
}

// `audio daemon run` startup:
signal(SIGPIPE, SIG_IGN)
let pidLock = try FileLock(Paths.pidFile)
guard pidLock.tryLockExclusive() else { exit(0) }            // healthy daemon exists; CLI will find it
try pidLock.writePID(getpid())                               // fd held (never closed) → lock dies with us
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.automaticTerminationDisabled, .suddenTerminationDisabled], reason: "audio-now daemon")
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { Task { await daemon.shutdown(reason: .signal(sig)) } }
    src.resume(); retainedSources.append(src)
}
try server.start(path: Paths.socket)                         // unlink-then-bind, safe under pidLock
dispatchMain()
```

---

## E. Failure Matrix (Q8)

| Failure | Detection | Daemon response | User-visible outcome |
|---|---|---|---|
| Worker crashes mid-job | Reader EOF + `Process` terminationHandler (deduped in actor) | Fade active audio (~50 ms), finalize partial WAV (header patched → valid file), respawn worker with backoff 0/2/8 s (give up after 3 crashes in 60 s), continue queue | `error worker_crashed` to owner + watchers; partial WAV path included; queued jobs still run |
| Worker hangs / ignores `cancel` | No `cancelled`/`done` within 5 s of cancel | SIGKILL worker, respawn (model reload cost accepted — correctness over warmth) | `stopped` already delivered instantly (audio faded at stop time); next job pays cold start |
| Client Ctrl-C mid-`say` | Connection EOF on netQueue | **Job keeps playing** (agent sessions are ephemeral; audio finishing is the desired UX). Watcher entry dropped; result cached for late `wait` | Speech continues; `audio stop` remains the kill switch |
| Daemon `kill -9` | Next CLI: connect fails; new daemon: `flock(daemon.pid)` succeeds → proves staleness | CLI spawn path runs; new daemon unlinks stale socket, binds fresh. Orphan worker exits via **stdin-EOF contract** (its pipe died with the daemon) | One command's worth of delay; no manual cleanup ever |
| Two CLIs race to spawn | `flock(spawn.lock)` serializes; both re-probe socket after acquiring; daemon-side pidfile lock makes a second daemon exit 0 | Loser attaches to winner's daemon | Both commands succeed |
| Audio device disappears (headphones) | `AVAudioEngineConfigurationChange` notification (engine auto-stops) | `try engine.start()` again (graph persists); ring intact → playback resumes on new default device; if no device after retries → job becomes render-only, `error audio_device_lost` but WAV completes | Sub-second blip, playback continues on speakers |
| System sleep during playback | Same config-change path on wake | Engine restart; ring backpressure means the worker was throttled during sleep too (nothing lost). Idle timer uses **ContinuousClock** (advances across sleep) so an idle daemon exits promptly on wake | Playback resumes where it paused |
| Disk full / WAV write fails | `write(2)` error on reader thread | Stop WAV writing, keep playing from ring; `done` carries `"wav_error":"..."` | Speech completes; file marked failed |
| Socket path > 104 bytes (`sun_path`) | Startup check in `SocketServer.start` | Hard error with message suggesting `AUDIO_NOW_HOME=/tmp/audio-now-$UID` | Clear failure instead of silent bind corruption |

---

## F. Top 5 Swift-Specific Pitfalls (and preemption)

1. **App Nap / timer throttling of a UI-less background daemon.** macOS will coalesce timers and nap a process with no windows and default QoS; audio I/O protects you *while rendering*, but socket latency and idle-timer precision degrade. Preempt: `ProcessInfo.beginActivity([.automaticTerminationDisabled, ...])` for daemon lifetime plus a `.latencyCritical | .userInitiated` activity held during active jobs; keep netQueue at `.userInitiated`.
2. **SIGPIPE kills the daemon.** A client that disconnects mid-event-stream, or a dead worker stdin, turns your next `write` into process death. Preempt: `signal(SIGPIPE, SIG_IGN)` as the first line of daemon startup, `SO_NOSIGPIPE` on every accepted fd, and treat `EPIPE`/`ECONNRESET` as normal connection close.
3. **Strict-concurrency Sendable pain at the C/real-time boundary.** The `AVAudioSourceNode` render block and DispatchSource handlers are `@Sendable`; Swift 6 will reject captured mutable state. Preempt: confine RT-shared state to small `final class ... : @unchecked Sendable` types whose entire safety story is `Synchronization.Atomic` (ring, gate, counters); capture them individually in the render block's capture list; never capture an actor there; and enforce the RT rules manually — no allocation, no `os_log`, no Dictionary/Array mutation, no locks (not even `Mutex`) inside the render block.
4. **Foundation `Process` pipe deadlocks and termination races.** An undrained stderr pipe (64 KB) silently wedges the worker mid-generation — it looks exactly like a model hang; and reader-EOF vs `terminationHandler` race produces double "worker died" handling. Preempt: stderr drain thread starts with the process, always; a single `workerEnded(generation:)` entry point on the actor deduplicates by worker generation counter; `terminationHandler` reaps, so no zombies.
5. **AVAudioEngine device-change behavior + permission red herrings.** The engine *stops itself* on default-device change and sleep/wake and will sit silent forever unless you observe `.AVAudioEngineConfigurationChange` and restart it (observer must be installed before first start). Separately: output-only playback needs **no** TCC permission, no mic entitlement, no Info.plist, no AVAudioSession (iOS-only API) — do not add any capture-adjacent code or you will manufacture permission prompts and debugging ghosts in a daemon context where TCC dialogs cannot even be shown.

Honorable mentions: `sockaddr_un` 104-byte path limit (checked at startup, see matrix); always unlink-before-bind (a stale socket file makes `bind` fail with `EADDRINUSE` even with no listener); use `ContinuousClock`, not `SuspendingClock`, for the idle timer.

---

## G. Build Order

1. **Codecs first (pure, test-driven):** `Messages`, `Framing`, `NDJSON` + round-trip tests. This freezes both protocols before any I/O exists and gives the Python worker author a concrete daemon↔worker contract immediately.
2. **`PCMRingBuffer` + `WavWriter`** + threaded stress test and header-math tests.
3. **`PlaybackEngine` + hidden `audio _tone` subcommand** feeding synthetic 133 ms sine frames at 1.3x cadence with injectable stalls: verify prebuffer, rebuffer-on-underrun, fade-stop (< 100 ms by ear and by counter), warm restart. First audible milestone; no worker, no daemon.
4. **`SocketServer` + `DaemonClient`** with `ping`/`status` round-trip, daemon in `--foreground` mode.
5. **Daemonization:** `Spawner`, `FileLock`, pidfile, log redirect, `daemon stop/logs`, SIGTERM path. Drill the two-CLI spawn race with a shell loop.
6. **`fakeworker` + `Worker` + `WorkerPipeReader`:** full `say` pipeline end-to-end against the fake (which also has crash/hang/ignore-cancel flags for step 9).
7. **`JobQueue` FSM + watchers + `stop`/`wait` + `IdleTimer`** (unit-tested with manual Sleeper; set `AUDIO_NOW_IDLE_SECS=5` for live testing).
8. **Real VibeVoice worker integration:** `warm`, `voices`, `render`, TTFA measurement, long-job soak (verify flat memory via ring backpressure).
9. **Failure drills from the matrix:** `kill -9` recovery, worker crash mid-job, headphone unplug, sleep/wake, disk-full WAV.

---

## Implementation deviations

- **JobQueue/IdleTimer as separate pure types → folded into the `Daemon` actor** (simple array + generation-counted `Task.sleep`). Fewer moving parts; the drills exercise the same behavior.
- **`voices` served by the daemon from the voices directory** (no worker involvement) — listing voices must not boot a 7B model. The worker keeps `list_voices` for protocol parity.
- **Messages are optional-bag Codable structs** (typed fields, snake_case wire, unknown-field-tolerant) rather than per-message enums.
- **Test target → `coretests` executable.** The CommandLineTools toolchain ships neither swift-testing nor XCTest; `make test` runs a framework-free assertion binary (22 checks).
- **`RenderState` holder class** for the render block: `Atomic`/`Mutex` are `~Copyable` and cannot be captured individually; they are reached through one `@unchecked Sendable` class reference (the design's capture-list-of-atomics sketch doesn't compile under Swift 6).
- **`AUDIO_NOW_WORKER_CMD` accepts a JSON array** (whitespace splitting broke on paths containing spaces).
- **fakeworker is silent by default** (`--audible` opts in): the user heard the 330Hz drill tone and reasonably read it as a fault.
- **`ttfa` = first PCM frame arriving at the daemon.** Audible onset follows within ~1 render callback + device latency (prebuffer is 1 frame and the first frame fills it); honest to ~0.1s without render-thread timestamping.
- **WavWriter default s16** (config `wavFormat`), `render --format f32` available.
- **Worker protocol addition:** `encode_voice` op + `voice_added` terminal event (voice cloning as a queued job).
- **Engine fix shipped alongside (vibevoice-mlx):** the 7B conversion's config scaling value collided with the KugelAudio single-segment heuristic, silently disabling multi-line/multi-speaker generation; identity fields now outrank the heuristic, and script lines always carry a `Speaker N:` tag (upstream format). Single-line output proven byte-identical before/after.
