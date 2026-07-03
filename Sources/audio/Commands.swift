import ArgumentParser
import AudioNowCore
import Foundation

// MARK: - say

struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak text on the speakers; blocks until playback finishes.")

    @Argument(help: "Text to speak (quote it), or a .txt/.md/.pdf path to read aloud.")
    var text: String

    @Option(name: .long, parsing: .singleValue,
            help: "Voice name, or N=name per speaker for dialogue (repeatable).")
    var voice: [String] = []

    @Option(help: "Generation seed (re-roll if output sounds wrong).")
    var seed: Int?

    @Option(help: "Also save the wav here (default: ~/.audio-now/out/).")
    var out: String?

    @Flag(name: [.customLong("async")],
          help: "Return immediately with a job id; audio wait <job> to re-sync.")
    var detach = false

    @Flag(help: "Stop whatever is playing first (barge-in).")
    var interrupt = false

    @Flag(help: "Speak a complex file anyway (skip the formatting refusal).")
    var force = false

    @Flag(help: "Print what would be spoken (after file parsing); no audio.")
    var preview = false

    @Flag(help: "Emit raw NDJSON events instead of human output.")
    var json = false

    func run() throws {
        var spoken = text
        var fileArg: String? = nil
        let resolved: ResolvedInput
        do { resolved = try Ingest.classify(text) }
        catch let e as IngestError {
            stderrPrint(e.description)
            throw ExitCode(2)
        }
        if case .file(let path, let ext) = resolved {
            let r = try ingestFileChecked(path: path, ext: ext)
            guard let t = try applyIngestPolicy(
                r, invocation: "audio say \(shellQuote(text))",
                force: force, preview: preview, json: json) else { return }
            spoken = t
            fileArg = text
        } else if preview {
            print(text)
            return
        }

        let words = spoken.split { $0.isWhitespace }.count
        let estimate = Double(words) / 2.4
        if estimate > 90 && !detach {
            let live = fileArg.map { "audio say --async \(shellQuote($0))" }
                ?? #"audio say --async "…""#
            let file = fileArg.map { "audio render \(shellQuote($0)) --out out.wav" }
                ?? "audio render file.txt --out file.wav"
            stderrPrint("""
            text is ~\(Int(estimate / 60)) min of speech — a blocking `say` would \
            outlive most tool timeouts. Use one of:
              \(live)        play live, returns a job id immediately
              \(file)    generate to a file instead
            """)
            throw ExitCode(2)
        }
        let client = try DaemonClient.connectOrSpawn(autoSpawn: true) {
            if !json { stderrPrint($0) }
        }
        if interrupt {
            // stop uses its own connection: one request per connection.
            if let stopper = try? DaemonClient.connect() {
                try stopper.send(Request(cmd: "stop"))
                _ = try? stopper.readEvent(timeout: 3)
            }
        }
        var req = Request(cmd: "say")
        req.text = spoken
        let (single, map) = parseVoices(voice)
        req.voice = single
        req.voices = map
        req.seed = seed
        req.out = out.map(absolutize)
        req.detach = detach
        try client.send(req)

        if detach {
            while let (line, ev) = try client.readEvent(timeout: 15) {
                if json { print(line) }
                if ev.event == "queued" {
                    if !json {
                        print("\(ev.job ?? "?") queued — audio wait \(ev.job ?? "") "
                              + "to block, audio stop to cancel")
                    }
                    return
                }
                if ev.event == "error" {
                    stderrPrint(describeError(ev))
                    throw ExitCode(2)
                }
            }
            throw CLIError.message("no response from daemon")
        }

        let terminal = try streamJob(client, json: json) { ev in
            guard !json else { return }
            switch ev.event {
            case "queued" where (ev.position ?? 0) > 0:
                stderrPrint("queued behind \(ev.position!) job(s) — "
                            + "audio stop cancels, audio status shows progress")
            case "ttfa":
                stderrPrint(String(format: "♪ first sound %.2fs",
                                   Double(ev.ms ?? 0) / 1000))
            case "progress":
                if let c = ev.chunk, let n = ev.chunks, n > 1 {
                    stderrPrint(String(format: "  chunk %d/%d — %.0fs generated",
                                       c, n, ev.generatedS ?? 0))
                }
            default:
                break
            }
        }
        if json { throw ExitCode(terminalExitCode(terminal)) }
        if terminal.event == "error" {
            stderrPrint(describeError(terminal))
            throw ExitCode(2)
        }
        var bits: [String] = []
        if let d = terminal.durationS ?? terminal.generatedS {
            bits.append(String(format: "spoke %.1fs", d))
        }
        if let ms = terminal.ms {
            bits.append(String(format: "first sound %.2fs", Double(ms) / 1000))
        }
        if let u = terminal.underruns, u > 0 { bits.append("⚠ \(u) underruns") }
        if let w = terminal.wav { bits.append("wav \(w)") }
        if terminal.reason == "stopped" { bits.append("(stopped early)") }
        print(bits.joined(separator: " · "))
        for w in terminal.warnings ?? [] { stderrPrint("⚠ \(w)") }
    }
}

// MARK: - render

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate speech to a wav file (no playback). Streams progress.")

    @Argument(help: "Text/markdown/PDF file to read, or '-' for stdin.")
    var file: String

    @Option(name: .long, parsing: .singleValue,
            help: "Voice name, or N=name per speaker for dialogue (repeatable).")
    var voice: [String] = []

    @Option(help: "Generation seed.")
    var seed: Int?

    @Option(help: "Output wav path (default: ~/.audio-now/out/<job>.wav).")
    var out: String?

    @Option(help: "Wav sample format: s16 or f32.")
    var format: String?

    @Flag(help: "Render a complex file anyway (skip the formatting refusal).")
    var force = false

    @Flag(help: "Print what would be narrated (after file parsing); no render.")
    var preview = false

    @Flag(help: "Emit raw NDJSON events instead of human output.")
    var json = false

    func run() throws {
        let text: String
        if file == "-" {
            let piped = String(decoding:
                FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            guard !piped.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                stderrPrint("input is empty")
                throw ExitCode(2)
            }
            if piped.filter(\.isNumber).count > 20 && !json {
                stderrPrint("⚠ input contains many digits — the model speaks "
                            + "numerals poorly; consider writing numbers as "
                            + "words first")
            }
            if preview { print(piped); return }
            text = piped
        } else {
            // The argument is declared a file: md/pdf are transformed for
            // speech (with the complexity policy); anything else is read as
            // plain text and only scanned (never refused).
            let path = absolutize(file)
            let ext = (path as NSString).pathExtension.lowercased()
            let kind = ["md", "markdown", "pdf"].contains(ext) ? ext : "txt"
            let r = try ingestFileChecked(path: path, ext: kind)
            guard let t = try applyIngestPolicy(
                r, invocation: "audio render \(shellQuote(file))",
                force: force, preview: preview, json: json) else { return }
            text = t
        }

        let client = try DaemonClient.connectOrSpawn(autoSpawn: true) {
            if !json { stderrPrint($0) }
        }
        var req = Request(cmd: "render")
        req.text = text
        let (single, map) = parseVoices(voice)
        req.voice = single
        req.voices = map
        req.seed = seed
        req.out = out.map(absolutize)
        req.format = format
        try client.send(req)

        let terminal = try streamJob(client, json: json) { ev in
            guard !json else { return }
            if ev.event == "progress", let c = ev.chunk, let n = ev.chunks {
                stderrPrint(String(format: "  chunk %d/%d — %.0fs (rtf %.2f)",
                                   c, n, ev.generatedS ?? 0, ev.rtf ?? 0))
            }
        }
        if json { throw ExitCode(terminalExitCode(terminal)) }
        if terminal.event == "error" {
            stderrPrint(describeError(terminal))
            throw ExitCode(2)
        }
        print(String(format: "rendered %.1fs -> %@",
                     terminal.durationS ?? 0, terminal.wav ?? "?"))
        for w in terminal.warnings ?? [] { stderrPrint("⚠ \(w)") }
    }
}

// MARK: - stop / wait / status / warm

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop playback now (50ms fade) and clear the queue.")

    @Flag(help: "Only stop the current job; keep queued jobs.")
    var currentOnly = false

    @Flag(help: "Emit raw NDJSON.")
    var json = false

    func run() throws {
        let client: DaemonClient
        do {
            client = try DaemonClient.connectOrSpawn(autoSpawn: false)
        } catch {
            if json { print(#"{"event":"stopped","jobs":[],"queue_cleared":0}"#) }
            else { print("nothing playing (daemon not running)") }
            return
        }
        var req = Request(cmd: "stop")
        req.scope = currentOnly ? "current" : "all"
        try client.send(req)
        if let (line, ev) = try client.readEvent(timeout: 5) {
            if json { print(line); return }
            let jobs = ev.jobs ?? []
            if jobs.isEmpty { print("nothing was playing") }
            else { print("stopped \(jobs.joined(separator: ", "))"
                         + ((ev.queueCleared ?? 0) > 0
                            ? " (+\(ev.queueCleared!) queued cleared)" : "")) }
        }
    }
}

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Block until a job (or everything) finishes.")

    @Argument(help: "Job id (omit to wait for full idle).")
    var job: String?

    @Option(help: "Give up after this many seconds (exit 3).")
    var timeout: Double?

    @Flag(help: "Emit raw NDJSON.")
    var json = false

    func run() throws {
        let client: DaemonClient
        do {
            client = try DaemonClient.connectOrSpawn(autoSpawn: false)
        } catch {
            if json { print(#"{"event":"idle"}"#) }
            else { print("idle (daemon not running)") }
            return
        }
        var req = Request(cmd: "wait")
        req.job = job
        try client.send(req)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let remain = deadline.map { $0.timeIntervalSinceNow }
            if let r = remain, r <= 0 {
                stderrPrint("wait timed out")
                throw ExitCode(3)
            }
            guard let (line, ev) = try client.readEvent(
                    timeout: remain.map { min($0, 5) } ?? 5) else { continue }
            if json { print(line) }
            switch ev.event {
            case "done", "voice_added":
                if !json {
                    print("\(ev.job ?? "") finished"
                          + (ev.reason == "stopped" ? " (stopped)" : "")
                          + (ev.wav.map { " · wav \($0)" } ?? ""))
                }
                return
            case "idle":
                if !json { print("idle") }
                return
            case "error":
                if !json { stderrPrint(describeError(ev)) }
                throw ExitCode(2)
            default:
                continue   // progress etc. while attached
            }
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Instant snapshot: warm/cold, playing what, queue, idle countdown.")

    @Flag(help: "Emit raw NDJSON.")
    var json = false

    func run() throws {
        let client: DaemonClient
        do {
            client = try DaemonClient.connectOrSpawn(autoSpawn: false)
        } catch {
            if json {
                print(#"{"event":"status","state":"cold"}"#)
            } else {
                print("cold — nothing running (the daemon starts automatically "
                      + "on `audio say`; ~4s to first sound from cold)")
            }
            return
        }
        try client.send(Request(cmd: "status"))
        guard let (line, ev) = try client.readEvent(timeout: 5),
              let st = ev.status else {
            throw CLIError.message("no status from daemon")
        }
        if json { print(line); return }
        var lines: [String] = []
        switch st.worker.state {
        case "ready":
            lines.append(String(format: "ready — expected time-to-sound %.1fs",
                                st.expectedTtfsS))
        case "warming":
            lines.append(String(format: "warming (%.1fs in, ~3s total)",
                                st.worker.warmingS ?? 0))
        default:
            lines.append("worker cold (boots on first say)")
        }
        if let a = st.active {
            var s = "\(a.kind) \(a.job): "
            if let c = a.chunk, let n = a.chunks { s += "chunk \(c)/\(n), " }
            s += String(format: "%.0fs generated", a.generatedS)
            if a.kind == "say" {
                s += String(format: ", %.0fs played", a.playedS)
            }
            lines.append(s)
        }
        if !st.queue.isEmpty {
            lines.append("queued: \(st.queue.joined(separator: ", "))")
        }
        if let idle = st.daemon.idleExitInS {
            lines.append(String(format: "idle shutdown in %.0f min", idle / 60))
        }
        if st.underrunsTotal > 0 {
            lines.append("⚠ \(st.underrunsTotal) underruns this session")
        }
        print(lines.joined(separator: "\n"))
    }
}

struct Warm: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pre-boot the model so the next say starts in <1s.")

    @Flag(help: "Emit raw NDJSON.")
    var json = false

    func run() throws {
        let client = try DaemonClient.connectOrSpawn(autoSpawn: true) {
            if !json { stderrPrint($0) }
        }
        try client.send(Request(cmd: "warm"))
        while true {
            guard let (line, ev) = try client.readEvent(timeout: 60) else {
                throw CLIError.message("warm timed out")
            }
            if json { print(line) }
            if ev.event == "ready" {
                if !json {
                    print((ev.wasWarm ?? false)
                          ? "already warm"
                          : String(format: "warm in %.1fs",
                                   Double(ev.loadMs ?? 0) / 1000))
                }
                return
            }
            if ev.event == "error" {
                stderrPrint(describeError(ev))
                throw ExitCode(2)
            }
        }
    }
}

// MARK: - voices

struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List voices, or add one from a clean 10-30s wav clip.",
        subcommands: [VoicesAdd.self])

    @Flag(help: "Emit raw NDJSON.")
    var json = false

    func run() throws {
        // Listing needs no daemon at all — read the catalog directly.
        let voices = VoiceCatalog.list(dir: Paths.voicesDir.path)
        if json {
            let infos = try voices.map { try Wire.encode($0) }
            print("{\"event\":\"voices\",\"voices\":[\(infos.joined(separator: ","))]}")
            return
        }
        if voices.isEmpty {
            print("no voices installed — audio voices add NAME clip.wav")
            return
        }
        for v in voices {
            var line = v.id + ((v.isDefault ?? false) ? "  (default)" : "")
            if let n = v.notes { line += "\n    \(n)" }
            print(line)
        }
    }
}

struct VoicesAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Encode a reference clip into a reusable voice.")

    @Argument(help: "Voice name (letters/digits/_/-).")
    var name: String

    @Argument(help: "Path to a 10-30s wav/m4a/mp3 of clean speech.")
    var clip: String

    @Flag(help: "Emit raw NDJSON.")
    var json = false

    func run() throws {
        let client = try DaemonClient.connectOrSpawn(autoSpawn: true) {
            if !json { stderrPrint($0) }
        }
        var req = Request(cmd: "voice_add")
        req.name = name
        req.wav = absolutize(clip)
        try client.send(req)
        let terminal = try streamJob(client, json: json)
        if json { throw ExitCode(terminalExitCode(terminal)) }
        if terminal.event == "error" {
            stderrPrint(describeError(terminal))
            throw ExitCode(2)
        }
        print("voice '\(terminal.voice ?? name)' added "
              + "(\(terminal.tokens ?? 0) tokens from "
              + String(format: "%.1fs", terminal.durationS ?? 0) + " of audio)")
        for w in terminal.warnings ?? [] { stderrPrint("⚠ \(w)") }
    }
}
