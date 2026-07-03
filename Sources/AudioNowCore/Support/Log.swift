import Foundation

/// Timestamped stderr logger. The daemon runs with stdout/stderr already
/// redirected to ~/.audio-now/log/daemon.log by its spawner, so plain
/// FileHandle.standardError is the log file in daemon mode and the
/// terminal in --foreground mode. Serialized through one queue so lines
/// from different threads never interleave.
public enum Log {
    private static let queue = DispatchQueue(label: "audio-now.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ msg: String) { write("INFO", msg) }
    public static func warn(_ msg: String) { write("WARN", msg) }
    public static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(stamp.string(from: Date())) [\(level)] \(msg)\n"
        queue.sync {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
