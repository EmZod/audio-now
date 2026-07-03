import Foundation
import Synchronization

/// Per-job reader context: where PCM goes. Swapped by the actor at job
/// start; flags flipped across threads are atomics.
public final class JobIO: @unchecked Sendable {
    public let jobId: String
    public let wav: WavWriter?
    public let playback: Bool
    public let discard = Atomic<Bool>(false)
    let notifiedFirstAudio = Atomic<Bool>(false)

    public init(jobId: String, wav: WavWriter?, playback: Bool) {
        self.jobId = jobId
        self.wav = wav
        self.playback = playback
    }
}

/// One spawned worker: Foundation Process + a blocking-read stdout thread
/// (framed protocol) + a stderr drain thread (mandatory — an undrained
/// stderr pipe wedges the worker, design pitfall #4).
public final class WorkerHandle: @unchecked Sendable {
    public let generation: Int
    private let process: Process
    private let stdinFD: Int32
    private let stdinLock = NSLock()
    private let ctx = Mutex<JobIO?>(nil)
    private let ring: PCMRingBuffer

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public init(command: [String], generation: Int, ring: PCMRingBuffer,
                daemon: Daemon) throws {
        precondition(!command.isEmpty)
        self.generation = generation
        self.ring = ring

        process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = env["HF_HUB_OFFLINE"] ?? "1"
        process.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor

        let gen = generation
        process.terminationHandler = { p in
            let status = p.terminationStatus
            Task { await daemon.workerEnded(generation: gen,
                                            detail: "exit status \(status)") }
        }
        try process.run()
        Log.info("worker g\(generation) spawned pid \(process.processIdentifier): "
                 + command.joined(separator: " "))

        startStdoutThread(fd: stdoutPipe.fileHandleForReading.fileDescriptor,
                          daemon: daemon)
        startStderrThread(fd: stderrPipe.fileHandleForReading.fileDescriptor)
    }

    // MARK: control

    public func setContext(_ io: JobIO?) {
        ctx.withLock { $0 = io }
    }

    public func send(_ cmd: WorkerCommand) {
        guard let line = try? Wire.encode(cmd) else { return }
        let data = Array((line + "\n").utf8)
        stdinLock.lock()
        defer { stdinLock.unlock() }
        // raw write(2): FileHandle.write raises an ObjC exception on EPIPE;
        // a dead worker's pipe is a normal condition here.
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let r = write(stdinFD, raw.baseAddress!.advanced(by: off),
                              raw.count - off)
                if r <= 0 {
                    if r < 0 && errno == EINTR { continue }
                    Log.warn("worker g\(generation) stdin write failed: \(errnoString())")
                    return
                }
                off += r
            }
        }
    }

    public func closeStdin() {
        stdinLock.lock()
        defer { stdinLock.unlock() }
        close(stdinFD)
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    public func kill9() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: pipes

    private func startStdoutThread(fd: Int32, daemon: Daemon) {
        let gen = generation
        // Captures self (a @unchecked Sendable holder): Mutex/Atomic members
        // are non-copyable and must be reached through the class reference.
        let t = Thread { [self] in
            let ring = self.ring
            var header = [UInt8](repeating: 0, count: 5)
            var payload = [UInt8](repeating: 0, count: Framing.maxPayload)
            defer {
                self.ctx.withLock { $0?.wav?.finalize() }
                Task { await daemon.workerEnded(generation: gen,
                                                detail: "stdout closed") }
            }
            while true {
                guard header.withUnsafeMutableBytes(
                        { readFully(fd, into: $0.baseAddress!, count: 5) })
                else { return }
                let len = Int(header[1]) | Int(header[2]) << 8
                        | Int(header[3]) << 16 | Int(header[4]) << 24
                guard len <= payload.count else {
                    Log.error("worker g\(gen): oversized frame \(len)")
                    return
                }
                guard payload.withUnsafeMutableBytes(
                        { readFully(fd, into: $0.baseAddress!, count: len) })
                else { return }

                switch header[0] {
                case UInt8(ascii: "A"):
                    let io = ctx.withLock { $0 }
                    guard let io else { continue }   // PCM with no job: drop
                    payload.withUnsafeBytes { raw in
                        let f = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                        let samples = len / 4
                        io.wav?.append(f, count: samples)
                        if !io.notifiedFirstAudio.exchange(
                                true, ordering: .relaxed) {
                            let job = io.jobId
                            Task { await daemon.firstAudio(job: job) }
                        }
                        guard io.playback else { return }
                        // Bounded ring: full => stop reading => pipe fills
                        // => worker write blocks => generation throttles.
                        while !io.discard.load(ordering: .relaxed) {
                            if ring.write(f, count: samples) { break }
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                    }
                case UInt8(ascii: "J"):
                    let data = Data(payload[0..<len])
                    guard let ev = try? JSONDecoder().decode(
                            WorkerEvent.self, from: data) else {
                        Log.warn("worker g\(gen): undecodable event "
                                 + String(decoding: data, as: UTF8.self))
                        continue
                    }
                    if ev.isTerminalForJob {
                        // Seal the wav BEFORE the actor sees the terminal
                        // event, so `done` always names a finished file.
                        ctx.withLock { $0?.wav?.finalize() }
                    }
                    Task { await daemon.workerEvent(generation: gen, ev) }
                default:
                    Log.error("worker g\(gen): unknown frame tag \(header[0])")
                    return
                }
            }
        }
        t.name = "worker-stdout-g\(generation)"
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func startStderrThread(fd: Int32) {
        let gen = generation
        let t = Thread {
            var splitter = LineSplitter()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let r = read(fd, &buf, buf.count)
                if r <= 0 {
                    if r < 0 && errno == EINTR { continue }
                    return
                }
                for line in splitter.feed(Data(buf[0..<r])) {
                    Log.info("[worker g\(gen)] \(line)")
                }
            }
        }
        t.name = "worker-stderr-g\(generation)"
        t.start()
    }
}
