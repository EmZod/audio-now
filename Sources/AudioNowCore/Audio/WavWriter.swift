import Foundation

/// Incremental WAV writer: header with placeholder sizes up front, samples
/// appended as they arrive, sizes patched on finalize — so a 55-minute job
/// never holds audio in RAM and a crash mid-job still leaves a valid
/// (truncated) file after the reader's finalize-on-terminal-event.
///
/// Called only from the worker pipe reader thread (or under its context
/// mutex), so no internal locking.
public final class WavWriter: @unchecked Sendable {
    public enum Format: String, Sendable {
        case s16, f32
    }

    public let path: String
    public let format: Format
    private let fd: Int32
    private let sampleRate: Int
    private var dataBytes: Int = 0
    private var finalized = false
    private var scratch: [Int16] = []
    public private(set) var writeError: String?

    public init(path: String, format: Format, sampleRate: Int = 24_000) throws {
        self.path = path
        self.format = format
        self.sampleRate = sampleRate
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw AudioNowError.io("open \(path): \(errnoString())")
        }
        writeHeader(dataBytes: 0)
        // pwrite does not advance the fd offset — seek past the header so
        // the first append lands after it, not over it.
        lseek(fd, 44, SEEK_SET)
    }

    private func writeHeader(dataBytes: Int) {
        let bitsPerSample = format == .s16 ? 16 : 32
        let audioFormat: UInt16 = format == .s16 ? 1 : 3   // PCM / IEEE float
        let byteRate = sampleRate * bitsPerSample / 8
        var h = Data(capacity: 44)
        h.append(contentsOf: Array("RIFF".utf8))
        h.appendLE(UInt32(36 + dataBytes))
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8))
        h.appendLE(UInt32(16))
        h.appendLE(audioFormat)
        h.appendLE(UInt16(1))                      // mono
        h.appendLE(UInt32(sampleRate))
        h.appendLE(UInt32(byteRate))
        h.appendLE(UInt16(bitsPerSample / 8))      // block align
        h.appendLE(UInt16(bitsPerSample))
        h.append(contentsOf: Array("data".utf8))
        h.appendLE(UInt32(dataBytes))
        _ = h.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }

    public func append(_ samples: UnsafePointer<Float>, count: Int) {
        guard !finalized, writeError == nil, count > 0 else { return }
        let ok: Bool
        switch format {
        case .f32:
            ok = writeAll(samples, bytes: count * 4)
        case .s16:
            if scratch.count < count {
                scratch = [Int16](repeating: 0, count: count)
            }
            for i in 0..<count {
                let v = samples[i]
                let clamped = max(-1.0, min(1.0, v))
                scratch[i] = Int16(clamped * 32767.0)
            }
            ok = scratch.withUnsafeBytes { raw in
                writeAll(raw.baseAddress!, bytes: count * 2)
            }
        }
        if ok {
            dataBytes += count * (format == .s16 ? 2 : 4)
        } else if writeError == nil {
            writeError = "write \(path): \(errnoString())"
            Log.error("wav write failed: \(writeError!) — playback continues")
        }
    }

    private func writeAll(_ ptr: UnsafeRawPointer, bytes: Int) -> Bool {
        var off = 0
        while off < bytes {
            let r = write(fd, ptr.advanced(by: off), bytes - off)
            if r <= 0 {
                if r < 0 && errno == EINTR { continue }
                return false
            }
            off += r
        }
        return true
    }

    public var durationS: Double {
        Double(dataBytes / (format == .s16 ? 2 : 4)) / Double(sampleRate)
    }

    public func finalize() {
        guard !finalized else { return }
        finalized = true
        writeHeader(dataBytes: dataBytes)
        close(fd)
    }

    deinit { if !finalized { finalize() } }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
