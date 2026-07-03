import Foundation

/// AF_UNIX server on one serial queue. Raw POSIX + DispatchSource: the
/// workload is <10 connections exchanging small NDJSON lines, so no
/// Network.framework, no NIO (design §Q3). All mutable state is confined
/// to `netQueue`; the Daemon actor only ever sees `ConnectionHandle`s.
public final class SocketServer: @unchecked Sendable {
    public typealias LineHandler = @Sendable (ConnectionHandle, String) -> Void
    public typealias CloseHandler = @Sendable (UInt64) -> Void

    private let netQueue = DispatchQueue(label: "audio-now.net", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UInt64: Connection] = [:]
    private var nextID: UInt64 = 0
    private var socketPath: String = ""
    private let onLine: LineHandler
    private let onClose: CloseHandler

    public init(onLine: @escaping LineHandler, onClose: @escaping CloseHandler) {
        self.onLine = onLine
        self.onClose = onClose
    }

    /// Caller must hold the daemon pidfile flock — that lock is the proof
    /// that any existing socket file is stale, making unlink-then-bind safe.
    public func start(path: String) throws {
        guard path.utf8.count < 104 else {
            throw AudioNowError.io(
                "socket path exceeds sockaddr_un limit (104): \(path) — "
                + "set AUDIO_NOW_HOME to a shorter path")
        }
        socketPath = path
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw AudioNowError.io("socket(): \(errnoString())")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { dst -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < dst.count else { return false }
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
            return true
        }
        guard ok else { throw AudioNowError.io("socket path too long") }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw AudioNowError.io("bind \(path): \(errnoString())")
        }
        chmod(path, 0o600)
        guard listen(listenFD, 16) == 0 else {
            throw AudioNowError.io("listen: \(errnoString())")
        }
        _ = fcntl(listenFD, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD,
                                                queue: netQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        acceptSource = src
        Log.info("listening on \(path)")
    }

    public func stop() {
        netQueue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            for conn in connections.values { conn.closeNow() }
            connections.removeAll()
            if !socketPath.isEmpty { unlink(socketPath) }
        }
    }

    /// Safe from any thread; delivery is netQueue-confined.
    public func send(to id: UInt64, line: String) {
        netQueue.async { [weak self] in
            self?.connections[id]?.enqueue(line + "\n")
        }
    }

    public func closeConnection(_ id: UInt64) {
        netQueue.async { [weak self] in
            self?.connections[id]?.closeNow()
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { break }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            nextID += 1
            let id = nextID
            let handle = ConnectionHandle(id: id) { [weak self] line in
                self?.send(to: id, line: line)
            }
            let conn = Connection(
                fd: fd, queue: netQueue,
                onLine: { [weak self] line in self?.onLine(handle, line) },
                onClosed: { [weak self] in
                    self?.connections[id] = nil
                    self?.onClose(id)
                })
            connections[id] = conn
        }
    }
}

/// What the Daemon actor holds instead of an fd.
public struct ConnectionHandle: Sendable {
    public let id: UInt64
    public let sendLine: @Sendable (String) -> Void

    public func send(_ event: Event) {
        if let line = try? Wire.encode(event) {
            sendLine(line)
        }
    }
}

/// One client connection; netQueue-confined.
final class Connection {
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var splitter = LineSplitter()
    private var outBuf = Data()
    private var closed = false
    private let onLine: (String) -> Void
    private let onClosed: () -> Void

    init(fd: Int32, queue: DispatchQueue,
         onLine: @escaping (String) -> Void,
         onClosed: @escaping () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onLine = onLine
        self.onClosed = onClosed
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readPending() }
        src.resume()
        readSource = src
    }

    private func readPending() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let r = read(fd, &buf, buf.count)
            if r > 0 {
                for line in splitter.feed(Data(buf[0..<r])) {
                    onLine(line)
                }
            } else if r == 0 {
                closeNow()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                closeNow()
                return
            }
        }
    }

    func enqueue(_ text: String) {
        guard !closed else { return }
        outBuf.append(Data(text.utf8))
        flush()
    }

    private func flush() {
        while !outBuf.isEmpty {
            let n = outBuf.withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                outBuf.removeFirst(n)
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                armWriteSource()
                return
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                closeNow()   // EPIPE/ECONNRESET: normal client departure
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func armWriteSource() {
        guard writeSource == nil else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.flush() }
        src.resume()
        writeSource = src
    }

    func closeNow() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        close(fd)
        onClosed()
    }
}
