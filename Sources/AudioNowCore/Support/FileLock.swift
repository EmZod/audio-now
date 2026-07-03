import Foundation

/// flock(2) wrapper. The fd is held open for the lifetime of the object —
/// the kernel releases the lock when the process dies, which is exactly
/// the staleness proof the daemon relies on.
public final class FileLock: @unchecked Sendable {
    public let fd: Int32
    public let path: String

    public init(path: String) throws {
        self.path = path
        fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw AudioNowError.io("open \(path): \(errnoString())")
        }
        // CLOEXEC: a CLI holding spawn.lock must not leak the fd (and the
        // lock with it) into the daemon it spawns.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Non-blocking exclusive lock. false = someone healthy holds it.
    public func tryLockExclusive() -> Bool {
        flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// Blocking exclusive lock with a deadline (polling; flock has no timeout).
    public func lockExclusive(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline {
                throw AudioNowError.timeout("flock \(path)")
            }
            usleep(50_000)
        }
    }

    public func unlock() { flock(fd, LOCK_UN) }

    public func writePID(_ pid: pid_t) {
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let s = "\(pid)\n"
        _ = s.withCString { write(fd, $0, strlen($0)) }
    }

    deinit { close(fd) }
}

public enum AudioNowError: Error, CustomStringConvertible {
    case io(String)
    case timeout(String)
    case daemonNotRunning
    case spawnFailed(String)
    case protocolError(String)
    case badRequest(String)

    public var description: String {
        switch self {
        case .io(let s): return "I/O error: \(s)"
        case .timeout(let s): return "timed out: \(s)"
        case .daemonNotRunning: return "daemon not running"
        case .spawnFailed(let s): return "could not start daemon: \(s)"
        case .protocolError(let s): return "protocol error: \(s)"
        case .badRequest(let s): return s
        }
    }
}

public func errnoString() -> String {
    String(cString: strerror(errno))
}
