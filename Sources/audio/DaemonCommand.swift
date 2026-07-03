import ArgumentParser
import AudioNowCore
import Foundation

// Daemon-lifetime retentions (pid lock, signal sources, activity token).
// nonisolated(unsafe): written once during single-threaded startup.
nonisolated(unsafe) private var retained: [Any] = []

struct DaemonCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Daemon lifecycle (rarely needed — it manages itself).",
        subcommands: [DaemonRun.self, DaemonStop.self, DaemonLogs.self])
}

struct DaemonRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run the daemon (normally auto-spawned).")

    @Flag(help: "Stay attached to the terminal (logs to stderr).")
    var foreground = false

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        try Paths.ensure()
        let config = try Config.load()

        let pidLock = try FileLock(path: Paths.pidPath)
        guard pidLock.tryLockExclusive() else {
            // A healthy daemon holds the lock; nothing to do.
            Log.info("daemon already running — exiting")
            return
        }
        pidLock.writePID(getpid())
        retained.append(pidLock)

        // App Nap defeats a UI-less daemon's timers and socket latency
        // (design pitfall #1).
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled,
                      .suddenTerminationDisabled],
            reason: "audio-now daemon")
        retained.append(activity)

        let engine = PlaybackEngine()
        let daemon = Daemon(config: config, engine: engine)
        let server = SocketServer(
            onLine: { handle, line in
                Task { await daemon.handle(handle, line: line) }
            },
            onClose: { id in
                Task { await daemon.connectionClosed(id) }
            })

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Task { await daemon.shutdown(reason: "signal \(sig)") }
            }
            src.resume()
            retained.append(src)
        }

        try server.start(path: Paths.socketPath)
        Task { await daemon.attach(server: server) }
        Log.info("audio-now \(audioNowVersion) daemon up, pid \(getpid()), "
                 + "idle timeout \(Int(config.idleTimeoutS))s"
                 + (foreground ? " (foreground)" : ""))
        dispatchMain()
    }
}

struct DaemonStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Gracefully stop the daemon and worker.")

    func run() throws {
        let client: DaemonClient
        do {
            client = try DaemonClient.connectOrSpawn(autoSpawn: false)
        } catch {
            print("daemon not running")
            return
        }
        try client.send(Request(cmd: "shutdown"))
        _ = try? client.readEvent(timeout: 3)
        // Wait for the socket to disappear as confirmation.
        for _ in 0..<50 {
            if (try? DaemonClient.connect()) == nil {
                print("daemon stopped")
                return
            }
            usleep(100_000)
        }
        print("daemon still shutting down (long job teardown?) — "
              + "check audio daemon logs")
    }
}

struct DaemonLogs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Show the daemon log tail.")

    @Option(help: "Lines to show.")
    var lines: Int = 60

    func run() throws {
        guard let data = FileManager.default.contents(atPath: Paths.logFile),
              !data.isEmpty else {
            print("no log at \(Paths.logFile)")
            return
        }
        let all = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        print(all.suffix(lines + 1).joined(separator: "\n"))
    }
}

// MARK: - hidden playback bench

struct Tone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_tone",
        abstract: "Playback-engine bench: synthetic frames, injectable stalls.",
        shouldDisplay: false)

    @Option(help: "Seconds of tone.")
    var seconds: Double = 3.0

    @Option(help: "Generation speed relative to realtime.")
    var rtf: Double = 1.3

    @Option(help: "Inject a feed stall at this second.")
    var stallAt: Double?

    @Option(help: "Stall duration in ms.")
    var stallMs: Int = 600

    @Option(help: "Prebuffer frames before audible start.")
    var prebuffer: Int = 1

    func run() throws {
        let engine = PlaybackEngine()
        engine.setPrebuffer(frames: prebuffer)
        try engine.warm()
        engine.beginJob()

        let frame = PlaybackEngine.frameSamples
        let total = Int(seconds * 24_000)
        var samples = [Float](repeating: 0, count: frame)
        let cadence = (Double(frame) / 24_000) / rtf
        var sent = 0
        var phase = 0.0
        let t0 = Date()
        var stalled = false
        while sent < total {
            for i in 0..<frame {
                phase += 2.0 * .pi * 440.0 / 24_000
                samples[i] = Float(sin(phase)) * 0.25
            }
            if let s = stallAt, !stalled, Double(sent) / 24_000 >= s {
                stalled = true
                stderrPrint("injecting \(stallMs)ms stall at \(s)s")
                usleep(useconds_t(stallMs * 1000))
            }
            samples.withUnsafeBufferPointer { buf in
                while !engine.ring.write(buf.baseAddress!, count: frame) {
                    usleep(10_000)
                }
            }
            sent += frame
            let target = t0.addingTimeInterval(Double(sent) / 24_000 / rtf)
            let sleepFor = target.timeIntervalSinceNow
            if sleepFor > 0 { usleep(useconds_t(sleepFor * 1_000_000)) }
        }
        engine.endOfStream()
        while !engine.isDrained { usleep(50_000) }
        print("played \(engine.playedSamples) samples "
              + String(format: "(%.2fs)", engine.playedSeconds)
              + ", underruns \(engine.underrunCount)"
              + ", prebuffer \(engine.prebufferFrames) frame(s)")
        if stallAt != nil && engine.underrunCount == 0 {
            stderrPrint("⚠ expected the injected stall to register an underrun")
            throw ExitCode(1)
        }
    }
}
