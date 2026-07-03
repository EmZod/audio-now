import Foundation

/// Worker stdout framing: [1 byte type][4 byte LE length][payload].
/// 'J' = UTF-8 JSON event, 'A' = float32le mono 24kHz PCM.
public enum Framing {
    public static let maxPayload = 1 << 16

    public enum Frame: Equatable, Sendable {
        case json(Data)
        case pcm(Data)
    }

    public static func encode(_ frame: Frame) -> Data {
        let (tag, payload): (UInt8, Data) = switch frame {
        case .json(let d): (UInt8(ascii: "J"), d)
        case .pcm(let d): (UInt8(ascii: "A"), d)
        }
        var out = Data(capacity: 5 + payload.count)
        out.append(tag)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Incremental parser for tests and non-blocking readers.
    public struct Parser: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func feed(_ data: Data) throws -> [Frame] {
            buffer.append(data)
            var frames: [Frame] = []
            while buffer.count >= 5 {
                let tag = buffer[buffer.startIndex]
                let len = buffer.withUnsafeBytes { raw -> UInt32 in
                    var v: UInt32 = 0
                    withUnsafeMutableBytes(of: &v) {
                        $0.copyBytes(from: raw[1..<5])
                    }
                    return UInt32(littleEndian: v)
                }
                guard len <= maxPayload else {
                    throw AudioNowError.protocolError("frame length \(len) exceeds cap")
                }
                let total = 5 + Int(len)
                guard buffer.count >= total else { break }
                let payload = buffer.subdata(
                    in: buffer.index(buffer.startIndex, offsetBy: 5)
                        ..< buffer.index(buffer.startIndex, offsetBy: total))
                switch tag {
                case UInt8(ascii: "J"): frames.append(.json(payload))
                case UInt8(ascii: "A"): frames.append(.pcm(payload))
                default:
                    throw AudioNowError.protocolError(
                        "unknown frame tag \(tag)")
                }
                buffer.removeFirst(total)
            }
            return frames
        }
    }
}

/// Blocking exact read; the worker pipe reader's primitive.
public func readFully(_ fd: Int32, into buf: UnsafeMutableRawPointer, count: Int) -> Bool {
    var off = 0
    while off < count {
        let r = read(fd, buf.advanced(by: off), count - off)
        if r <= 0 {
            if r < 0 && errno == EINTR { continue }
            return false
        }
        off += r
    }
    return true
}
