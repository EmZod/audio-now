import Foundation

public let audioNowVersion = "0.1.0"

/// The control plane. The ONLY place with mutable daemon state; everything
/// slow (PCM, disk, blocking reads) happens on other threads, so control
/// operations answer instantly even during a 55-minute job.
public actor Daemon {
    // MARK: types

    enum WorkerState {
        case cold
        case warming(wallSince: Date)
        case ready
    }

    enum JobKind: String {
        case say, render, voiceAdd
    }

    struct PendingJob {
        let id: String
        let kind: JobKind
        let request: Request
        let owner: ConnectionHandle?
    }

    final class ActiveJob {
        let id: String
        let kind: JobKind
        let request: Request
        let owner: ConnectionHandle?
        var watchers: [ConnectionHandle] = []
        let jobIO: JobIO?
        let startedAt: Date
        var firstAudioMs: Int?
        var generatedS: Double = 0
        var chunk: Int?
        var chunks: Int?
        var stopping = false
        let playedBaseline: Int
        let underrunBaseline: Int

        init(id: String, kind: JobKind, request: Request,
             owner: ConnectionHandle?, jobIO: JobIO?,
             playedBaseline: Int, underrunBaseline: Int) {
            self.id = id
            self.kind = kind
            self.request = request
            self.owner = owner
            self.jobIO = jobIO
            self.startedAt = Date()
            self.playedBaseline = playedBaseline
            self.underrunBaseline = underrunBaseline
        }
    }

    enum Outcome {
        case completed(WorkerEvent)
        case stopped
        case failed(code: String, message: String, hint: String?)
        case voiceAdded(WorkerEvent)
    }

    // MARK: state

    let config: Config
    let engine: PlaybackEngine
    private var server: SocketServer?
    private let bootedAt = Date()

    private var worker: WorkerHandle?
    private var workerState: WorkerState = .cold
    private var workerGeneration = 0
    private var endedGenerations: Set<Int> = []
    private var crashTimes: [Date] = []
    private var workerLoadMs: Int?

    private var queue: [PendingJob] = []
    private var active: ActiveJob?
    private var queuedWatchers: [String: [ConnectionHandle]] = [:]
    private var recent: [(id: String, event: Event)] = []
    private var warmWaiters: [ConnectionHandle] = []
    private var idleWaiters: [ConnectionHandle] = []
    private var jobCounter = 0

    private var idleGeneration = 0
    private var idleDeadline: Date?
    private var prebufferFrames = 1          // escalates to 2 after any underrun
    private var shuttingDown = false

    public init(config: Config, engine: PlaybackEngine) {
        self.config = config
        self.engine = engine
    }

    public func attach(server: SocketServer) {
        self.server = server
        rearmIdleTimer()
    }

    // MARK: - request routing

    public func handle(_ conn: ConnectionHandle, line: String) {
        guard !shuttingDown else {
            conn.send(.error(code: "daemon_shutting_down",
                             message: "daemon is shutting down"))
            return
        }
        let req: Request
        do {
            req = try Wire.decode(Request.self, from: line)
        } catch {
            conn.send(.error(code: "bad_request",
                             message: "unparseable request: \(error)"))
            return
        }
        switch req.cmd {
        case "ping":
            var e = Event(event: "pong")
            e.pid = Int(getpid())
            e.version = audioNowVersion
            conn.send(e)
        case "say":
            enqueueJob(kind: .say, req: req, conn: conn)
        case "render":
            enqueueJob(kind: .render, req: req, conn: conn)
        case "voice_add":
            guard req.name != nil, req.wav != nil else {
                conn.send(.error(code: "bad_request",
                                 message: "voice_add needs 'name' and 'wav'"))
                return
            }
            enqueueJob(kind: .voiceAdd, req: req, conn: conn)
        case "stop":
            stop(conn, req)
        case "wait":
            wait(conn, req)
        case "status":
            conn.send(statusEvent())
        case "voices":
            conn.send(voicesEvent())
        case "warm":
            warm(conn)
        case "shutdown":
            conn.send(Event(event: "shutdown_started"))
            Task { await self.shutdown(reason: "shutdown command") }
        default:
            conn.send(.error(code: "bad_request",
                             message: "unknown cmd '\(req.cmd)'"))
        }
    }

    public func connectionClosed(_ id: UInt64) {
        // Jobs keep running when their client leaves (design §Q8);
        // just drop the departed connection from every audience list.
        active?.watchers.removeAll { $0.id == id }
        for key in queuedWatchers.keys {
            queuedWatchers[key]?.removeAll { $0.id == id }
        }
        warmWaiters.removeAll { $0.id == id }
        idleWaiters.removeAll { $0.id == id }
    }

    // MARK: - jobs

    private func enqueueJob(kind: JobKind, req: Request, conn: ConnectionHandle) {
        if kind != .voiceAdd,
           (req.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conn.send(.error(code: "bad_request", message: "missing 'text'"))
            return
        }
        jobCounter += 1
        let id = String(format: "j-%06d", jobCounter)
        let detached = req.detach ?? false
        let job = PendingJob(id: id, kind: kind, request: req,
                             owner: detached ? nil : conn)
        queue.append(job)
        var e = Event(event: "queued")
        e.job = id
        e.position = queue.count - 1 + (active != nil ? 1 : 0)
        conn.send(e)
        maybeStart()
    }

    private func maybeStart() {
        guard active == nil, !queue.isEmpty, !shuttingDown else { return }
        switch workerState {
        case .cold:
            ensureWorker()
            return
        case .warming:
            return
        case .ready:
            break
        }
        guard let worker else { return }
        let job = queue.removeFirst()

        var jobIO: JobIO?
        if job.kind != .voiceAdd {
            let outPath = job.request.out
                ?? "\(config.outDir)/\(job.id)_\(job.kind.rawValue).wav"
            let format = WavWriter.Format(
                rawValue: job.request.format ?? config.wavFormat) ?? .s16
            let wav = try? WavWriter(path: outPath, format: format)
            if wav == nil {
                Log.error("cannot open wav at \(outPath); job continues without file")
            }
            jobIO = JobIO(jobId: job.id, wav: wav, playback: job.kind == .say)
        }
        worker.setContext(jobIO)

        if job.kind == .say {
            engine.setPrebuffer(frames: prebufferFrames)
            do {
                try engine.warm()
            } catch {
                Log.error("audio engine start failed: \(error) — "
                          + "job continues as render-only")
            }
            engine.beginJob()
        }

        let activeJob = ActiveJob(
            id: job.id, kind: job.kind, request: job.request, owner: job.owner,
            jobIO: jobIO,
            playedBaseline: engine.playedSamples,
            underrunBaseline: engine.underrunCount)
        activeJob.watchers = queuedWatchers.removeValue(forKey: job.id) ?? []
        active = activeJob

        var cmd = WorkerCommand(op: job.kind == .voiceAdd ? "encode_voice" : "generate")
        cmd.job = job.id
        cmd.text = job.request.text
        cmd.voice = job.request.voice
        cmd.voices = job.request.voices
        cmd.seed = job.request.seed
        cmd.name = job.request.name
        cmd.wav = job.request.wav
        worker.send(cmd)
        Log.info("job \(job.id) (\(job.kind.rawValue)) started")
    }

    /// Every event a job's audience should see goes through here.
    private func tellAudience(_ job: ActiveJob, _ event: Event) {
        job.owner?.send(event)
        for w in job.watchers { w.send(event) }
    }

    private func finishActive(_ outcome: Outcome) {
        guard let job = active else { return }
        active = nil
        worker?.setContext(nil)

        var e: Event
        switch outcome {
        case .completed(let wev):
            e = Event(event: "done")
            e.reason = "completed"
            e.tokens = wev.tokens
            e.generatedS = wev.generatedS
            e.warnings = wev.warnings
        case .stopped:
            e = Event(event: "done")
            e.reason = "stopped"
        case .failed(let code, let message, let hint):
            e = .error(job: job.id, code: code, message: message, hint: hint)
        case .voiceAdded(let wev):
            e = Event(event: "voice_added")
            e.voice = wev.name
            e.tokens = wev.tokens
            e.durationS = wev.durationS
            e.warnings = wev.warnings
        }
        e.job = job.id
        if let io = job.jobIO, let wav = io.wav {
            e.wav = wav.path
            if e.durationS == nil { e.durationS = wav.durationS }
            if let werr = wav.writeError {
                e.warnings = (e.warnings ?? []) + ["wav write failed: \(werr)"]
            }
        }
        if job.kind == .say {
            e.ms = job.firstAudioMs
            let unders = engine.underrunCount - job.underrunBaseline
            e.underruns = unders
            e.playedS = Double(engine.playedSamples - job.playedBaseline) / 24_000
            if unders > 0 && prebufferFrames < 2 {
                prebufferFrames = 2
                Log.warn("underruns detected — initial prebuffer escalated to "
                         + "2 frames for this daemon session (mid-stream "
                         + "stalls rebuffer to 2s before resuming)")
            }
        }
        tellAudience(job, e)
        recent.append((job.id, e))
        if recent.count > 32 { recent.removeFirst() }
        Log.info("job \(job.id) finished: \(e.event)/\(e.reason ?? e.code ?? "-") "
                 + "wav=\(e.wav ?? "-") dur=\(e.durationS.map { String(format: "%.1f", $0) } ?? "-")s")

        if queue.isEmpty && active == nil {
            for w in idleWaiters { w.send(Event(event: "idle")) }
            idleWaiters.removeAll()
        }
        rearmIdleTimer()
        maybeStart()
    }

    // MARK: - worker lifecycle

    private func ensureWorker() {
        guard case .cold = workerState, !shuttingDown else { return }
        let recentCrashes = crashTimes.filter { $0 > Date().addingTimeInterval(-60) }
        guard recentCrashes.count < 3 else {
            Log.error("worker crashed \(recentCrashes.count)x in 60s — "
                      + "not respawning; failing queued jobs")
            failQueue(code: "worker_unavailable",
                      message: "worker keeps crashing; see \(Paths.logFile)")
            return
        }
        workerGeneration += 1
        workerState = .warming(wallSince: Date())
        do {
            worker = try WorkerHandle(
                command: config.workerCommand,
                generation: workerGeneration,
                ring: engine.ring, daemon: self)
        } catch {
            workerState = .cold
            Log.error("worker spawn failed: \(error)")
            failQueue(code: "worker_unavailable",
                      message: "cannot start worker: \(error)",
                      hint: "check pythonPath in \(Paths.configPath)")
        }
    }

    private func failQueue(code: String, message: String, hint: String? = nil) {
        for job in queue {
            let e = Event.error(job: job.id, code: code, message: message, hint: hint)
            job.owner?.send(e)
            for w in queuedWatchers.removeValue(forKey: job.id) ?? [] { w.send(e) }
            recent.append((job.id, e))
        }
        queue.removeAll()
        for w in warmWaiters {
            w.send(.error(code: code, message: message, hint: hint))
        }
        warmWaiters.removeAll()
        rearmIdleTimer()
    }

    public func workerEvent(generation: Int, _ ev: WorkerEvent) {
        guard generation == workerGeneration else { return }   // stale worker
        switch ev.event {
        case "ready":
            workerState = .ready
            workerLoadMs = ev.loadMs
            Log.info("worker ready in \(ev.loadMs ?? 0)ms")
            for w in warmWaiters {
                var e = Event(event: "ready")
                e.loadMs = ev.loadMs
                e.wasWarm = false
                w.send(e)
            }
            warmWaiters.removeAll()
            rearmIdleTimer()
            maybeStart()
        case "started":
            guard let job = active, job.id == ev.job else { return }
            job.chunks = ev.chunks
            var e = Event(event: "started")
            e.job = job.id
            e.voice = ev.voice ?? job.request.voice
            e.chunks = ev.chunks
            tellAudience(job, e)
        case "pcm_begin":
            break   // frames themselves are handled on the reader thread
        case "progress":
            guard let job = active, job.id == ev.job else { return }
            job.generatedS = ev.generatedS ?? job.generatedS
            job.chunk = ev.chunk
            job.chunks = ev.chunks ?? job.chunks
            var e = Event(event: "progress")
            e.job = job.id
            e.chunk = ev.chunk
            e.chunks = ev.chunks
            e.generatedS = ev.generatedS
            e.rtf = ev.rtf
            if job.kind == .say {
                e.playedS = Double(engine.playedSamples - job.playedBaseline) / 24_000
            }
            tellAudience(job, e)
        case "done":
            guard let job = active, job.id == ev.job else { return }
            if job.kind == .say {
                engine.endOfStream()
                let engine = self.engine
                let jobId = job.id
                Task {
                    // Drain wait happens OFF the actor; `done` means the
                    // speakers went quiet, not that generation ended.
                    let deadline = Date().addingTimeInterval(50)
                    while !engine.isDrained && Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if !engine.isDrained { engine.forceIdle() }
                    self.drainComplete(jobId: jobId, ev)   // Task inherits actor isolation
                }
            } else {
                finishActive(.completed(ev))
            }
        case "cancelled":
            guard let job = active, job.id == ev.job else { return }
            finishActive(.stopped)
        case "voice_added":
            guard let job = active else { return }
            finishActive(.voiceAdded(ev))
        case "error":
            if let job = active, ev.job == nil || ev.job == job.id {
                engine.stopNow()
                finishActive(.failed(code: "job_failed",
                                     message: ev.message ?? "worker error",
                                     hint: nil))
            } else {
                Log.warn("worker error (no active job): \(ev.message ?? "?")")
            }
        case "fatal":
            Log.error("worker fatal: \(ev.message ?? "?")")
            worker?.kill9()
        case "voices", "pong":
            break
        default:
            Log.warn("unknown worker event \(ev.event)")
        }
    }

    private func drainComplete(jobId: String, _ ev: WorkerEvent) {
        guard let job = active, job.id == jobId else { return }
        finishActive(.completed(ev))
    }

    public func firstAudio(job id: String) {
        guard let job = active, job.id == id, job.firstAudioMs == nil else { return }
        let ms = Int(Date().timeIntervalSince(job.startedAt) * 1000)
        job.firstAudioMs = ms
        var e = Event(event: "ttfa")
        e.job = id
        e.ms = ms
        tellAudience(job, e)
    }

    /// Single deduplicated entry point for "the worker is gone", reached
    /// from both the stdout-EOF thread and the Process terminationHandler.
    public func workerEnded(generation: Int, detail: String) {
        guard generation == workerGeneration,
              !endedGenerations.contains(generation) else { return }
        endedGenerations.insert(generation)
        let wasWarming: Bool
        if case .warming = workerState { wasWarming = true } else { wasWarming = false }
        workerState = .cold
        worker = nil
        crashTimes.append(Date())
        if shuttingDown { return }
        Log.error("worker g\(generation) ended (\(detail))")

        if active != nil {
            engine.stopNow()
            var hint = "partial wav kept"
            if wasWarming { hint = "worker died during model load" }
            finishActive(.failed(code: "worker_crashed",
                                 message: "worker died mid-job (\(detail))",
                                 hint: hint))
        }
        if wasWarming {
            failQueue(code: "worker_unavailable",
                      message: "worker died during model load (\(detail))",
                      hint: "check \(Paths.logFile)")
        } else if !queue.isEmpty {
            // Respawn with backoff proportional to recent crash count.
            let recentCrashes = crashTimes.filter {
                $0 > Date().addingTimeInterval(-60)
            }.count
            let delay = [0.0, 2.0, 8.0][min(recentCrashes - 1, 2)]
            Log.info("respawning worker in \(delay)s for \(queue.count) queued job(s)")
            Task {
                try? await Task.sleep(for: .seconds(delay))
                self.respawnIfNeeded()   // Task inherits actor isolation
            }
        }
    }

    private func respawnIfNeeded() {
        if case .cold = workerState, !queue.isEmpty { ensureWorker() }
        maybeStart()
    }

    // MARK: - control verbs

    private func stop(_ conn: ConnectionHandle, _ req: Request) {
        var stoppedJobs: [String] = []
        let clearQueue = (req.scope ?? "all") == "all"

        if let job = active, req.job == nil || req.job == job.id {
            stoppedJobs.append(job.id)
            if !job.stopping {
                job.stopping = true
                job.jobIO?.discard.store(true, ordering: .relaxed)
                engine.stopNow()
                worker?.send({ var c = WorkerCommand(op: "cancel"); c.job = job.id; return c }())
                // Hung-worker escalation: if no `cancelled` lands in 5s, the
                // worker is stuck inside the GPU loop — kill it (correctness
                // over warmth; next job pays the 3s reload).
                let jobId = job.id
                let gen = workerGeneration
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await self.killIfStillActive(jobId: jobId, generation: gen)
                }
            }
        }
        var cleared = 0
        if clearQueue && !queue.isEmpty {
            cleared = queue.count
            stoppedJobs.append(contentsOf: queue.map(\.id))
            let jobs = queue
            queue.removeAll()
            for job in jobs {
                var e = Event(event: "done")
                e.job = job.id
                e.reason = "stopped"
                job.owner?.send(e)
                for w in queuedWatchers.removeValue(forKey: job.id) ?? [] {
                    w.send(e)
                }
                recent.append((job.id, e))
            }
        }
        var e = Event(event: "stopped")
        e.jobs = stoppedJobs
        e.queueCleared = cleared
        conn.send(e)
        rearmIdleTimer()
    }

    private func killIfStillActive(jobId: String, generation: Int) {
        guard let job = active, job.id == jobId, job.stopping,
              generation == workerGeneration else { return }
        Log.error("worker ignored cancel for 5s — SIGKILL")
        worker?.kill9()
    }

    private func wait(_ conn: ConnectionHandle, _ req: Request) {
        guard let jobId = req.job else {
            if active == nil && queue.isEmpty {
                conn.send(Event(event: "idle"))
            } else {
                idleWaiters.append(conn)
            }
            return
        }
        if let job = active, job.id == jobId {
            job.watchers.append(conn)
        } else if queue.contains(where: { $0.id == jobId }) {
            queuedWatchers[jobId, default: []].append(conn)
        } else if let past = recent.last(where: { $0.id == jobId }) {
            conn.send(past.event)
        } else {
            conn.send(.error(code: "unknown_job",
                             message: "no such job \(jobId)",
                             hint: "audio status lists active and queued jobs"))
        }
    }

    private func warm(_ conn: ConnectionHandle) {
        switch workerState {
        case .ready:
            var e = Event(event: "ready")
            e.wasWarm = true
            e.loadMs = 0
            conn.send(e)
        case .warming:
            warmWaiters.append(conn)
        case .cold:
            warmWaiters.append(conn)
            ensureWorker()
        }
    }

    private func statusEvent() -> Event {
        let workerInfo: StatusInfo.WorkerInfo
        switch workerState {
        case .cold:
            workerInfo = .init(state: "cold", pid: nil, warmingS: nil)
        case .warming(let since):
            workerInfo = .init(state: "warming", pid: worker.map { Int($0.pid) },
                               warmingS: Date().timeIntervalSince(since))
        case .ready:
            workerInfo = .init(state: "ready", pid: worker.map { Int($0.pid) },
                               warmingS: nil)
        }
        var activeInfo: StatusInfo.ActiveInfo?
        if let job = active {
            activeInfo = .init(
                job: job.id, kind: job.kind.rawValue,
                generatedS: job.generatedS,
                playedS: Double(engine.playedSamples - job.playedBaseline) / 24_000,
                chunk: job.chunk, chunks: job.chunks)
        }
        let idleIn: Double? = (active == nil && queue.isEmpty)
            ? idleDeadline.map { max(0, $0.timeIntervalSinceNow) } : nil
        let expected: Double
        switch workerState {
        case .ready: expected = 0.6
        case .warming: expected = 2.0
        case .cold: expected = 4.0
        }
        let info = StatusInfo(
            daemon: .init(pid: Int(getpid()),
                          uptimeS: Date().timeIntervalSince(bootedAt),
                          idleExitInS: idleIn),
            worker: workerInfo,
            active: activeInfo,
            queue: queue.map(\.id),
            underrunsTotal: engine.underrunCount,
            expectedTtfsS: expected)
        var e = Event(event: "status")
        e.status = info
        e.version = audioNowVersion
        return e
    }

    private func voicesEvent() -> Event {
        var e = Event(event: "voices")
        e.voices = VoiceCatalog.list(dir: config.voicesDir)
        return e
    }

    // MARK: - idle & shutdown

    private func rearmIdleTimer() {
        idleGeneration += 1
        let gen = idleGeneration
        let timeout = config.idleTimeoutS
        idleDeadline = Date().addingTimeInterval(timeout)
        Task {
            // ContinuousClock: advances across system sleep, so an idle
            // daemon exits promptly on wake (design pitfall list).
            try? await Task.sleep(for: .seconds(timeout), clock: .continuous)
            await self.idleFired(generation: gen)
        }
    }

    private func idleFired(generation: Int) {
        guard generation == idleGeneration, !shuttingDown,
              active == nil, queue.isEmpty else { return }
        if case .warming = workerState { return }
        Log.info("idle for \(Int(config.idleTimeoutS))s — shutting down")
        Task { await self.shutdown(reason: "idle timeout") }
    }

    public func shutdown(reason: String) async {
        guard !shuttingDown else { return }
        shuttingDown = true
        Log.info("shutdown: \(reason)")
        engine.stopNow()

        if let job = active {
            let e = Event.error(job: job.id, code: "cancelled_shutdown",
                                message: "daemon shut down (\(reason))",
                                hint: nil)
            tellAudience(job, e)
            job.jobIO?.discard.store(true, ordering: .relaxed)
            job.jobIO?.wav?.finalize()
            active = nil
        }
        failQueue(code: "cancelled_shutdown",
                  message: "daemon shut down (\(reason))")

        if let worker {
            worker.send(WorkerCommand(op: "shutdown"))
            worker.closeStdin()
            for _ in 0..<20 where worker.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if worker.isRunning {
                worker.terminate()
                try? await Task.sleep(for: .seconds(1))
            }
            if worker.isRunning { worker.kill9() }
        }
        server?.stop()
        Log.info("bye")
        exit(0)
    }
}

/// Voice listing straight from the voices directory — no 7B boot needed
/// just to enumerate names.
public enum VoiceCatalog {
    public static func list(dir: String) -> [VoiceInfo] {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
            ?? []
        let names = files.filter { $0.pathExtension == "safetensors" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        var defaultName = names.first
        var notes: [String: String] = [:]
        if let data = try? Data(contentsOf: url.appendingPathComponent("voices.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["default"] as? String, names.contains(d) {
                defaultName = d
            }
            notes = obj["notes"] as? [String: String] ?? [:]
        }
        return names.map {
            VoiceInfo(id: $0, isDefault: $0 == defaultName ? true : nil,
                      notes: notes[$0])
        }
    }
}
