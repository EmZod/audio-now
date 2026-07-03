import Foundation

/// ~/.audio-now layout — the only durable state in the system.
/// AUDIO_NOW_HOME overrides the root (also the escape hatch for the
/// sockaddr_un 104-byte path limit).
public enum Paths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["AUDIO_NOW_HOME"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".audio-now")
    }

    public static var runDir: URL { home.appendingPathComponent("run") }
    public static var logDir: URL { home.appendingPathComponent("log") }
    public static var outDir: URL { home.appendingPathComponent("out") }
    public static var voicesDir: URL { home.appendingPathComponent("voices") }
    public static var modelDir: URL { home.appendingPathComponent("model") }

    public static var socketPath: String { runDir.appendingPathComponent("daemon.sock").path }
    public static var pidPath: String { runDir.appendingPathComponent("daemon.pid").path }
    public static var spawnLockPath: String { runDir.appendingPathComponent("spawn.lock").path }
    public static var logFile: String { logDir.appendingPathComponent("daemon.log").path }
    public static var configPath: String { home.appendingPathComponent("config.json").path }

    /// Create the directory tree (run/ is 0700 — it holds the socket).
    public static func ensure() throws {
        let fm = FileManager.default
        for dir in [home, logDir, outDir, voicesDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createDirectory(
            at: runDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
