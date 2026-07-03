import Foundation

/// Synchronous client for the CLI: one connection, one request, then a
/// stream of events until a terminal one. Blocking with select-based
/// timeouts — a CLI has no need for async machinery.
public final class DaemonClient {
    private let fd: Int32
    private var splitter = LineSplitter()
    private var pending: [String] = []

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit { close(fd) }

    public static func connect(path: String = Paths.socketPath) throws -> DaemonClient {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AudioNowError.io("socket: \(errnoString())") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { dst -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < dst.count else { return false }
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
            return true
        }
        guard ok else { close(fd); throw AudioNowError.io("socket path too long") }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else {
            let e = errno
            close(fd)
            throw AudioNowError.io("connect: \(String(cString: strerror(e)))")
        }
        return DaemonClient(fd: fd)
    }

    /// Connect, auto-spawning the daemon when allowed. `stop`/`wait`/`status`
    /// pass autoSpawn=false: they must never boot a 7B model to report that
    /// nothing is happening.
    public static func connectOrSpawn(
        autoSpawn: Bool,
        spawnNote: (String) -> Void = { _ in }
    ) throws -> DaemonClient {
        if let c = try? connect() { return c }
        guard autoSpawn else { throw AudioNowError.daemonNotRunning }
        try Paths.ensure()
        let lock = try FileLock(path: Paths.spawnLockPath)
        try lock.lockExclusive(timeout: 15)
        defer { lock.unlock() }
        if let c = try? connect() { return c }   // lost the race: winner's daemon
        spawnNote("starting audio-now daemon…")
        try Spawner.spawnDetachedDaemon()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            usleep(100_000)
            if let c = try? connect() { return c }
        }
        throw AudioNowError.spawnFailed(
            "daemon did not come up within 12s — see \(Paths.logFile)")
    }

    public func send(_ req: Request) throws {
        let line = try Wire.encode(req) + "\n"
        let data = Array(line.utf8)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let r = write(fd, raw.baseAddress!.advanced(by: off),
                              raw.count - off)
                if r <= 0 {
                    if r < 0 && errno == EINTR { continue }
                    return false
                }
                off += r
            }
            return true
        }
        guard ok else { throw AudioNowError.io("send: \(errnoString())") }
    }

    /// Next (rawLine, decodedEvent). nil = timeout. Throws on EOF/error.
    public func readEvent(timeout: TimeInterval?) throws -> (String, Event)? {
        while true {
            if !pending.isEmpty {
                let line = pending.removeFirst()
                if let ev = try? Wire.decode(Event.self, from: line) {
                    return (line, ev)
                }
                continue
            }
            if let timeout {
                var readSet = fd_set()
                fdZero(&readSet)
                fdSet(fd, &readSet)
                var tv = timeval(tv_sec: Int(timeout),
                                 tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
                let r = select(fd + 1, &readSet, nil, nil, &tv)
                if r == 0 { return nil }
                if r < 0 {
                    if errno == EINTR { continue }
                    throw AudioNowError.io("select: \(errnoString())")
                }
            }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                pending.append(contentsOf: splitter.feed(Data(buf[0..<n])))
            } else if n == 0 {
                throw AudioNowError.io("daemon closed the connection")
            } else if errno != EINTR {
                throw AudioNowError.io("read: \(errnoString())")
            }
        }
    }
}

// fd_set helpers (Darwin's FD_SET is a macro, unavailable in Swift)
private func fdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) {
        $0.initializeMemory(as: UInt8.self, repeating: 0)
    }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutableBytes(of: &set.fds_bits) { raw in
        let bits = raw.bindMemory(to: Int32.self)
        bits[intOffset] |= Int32(bitPattern: UInt32(1) << bitOffset)
    }
}
