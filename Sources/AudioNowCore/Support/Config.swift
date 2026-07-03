import Foundation

/// ~/.audio-now/config.json — written by `make install`, read at daemon boot.
/// Everything has a sane default so a missing file still works if the
/// standard layout exists; a missing *python* is the one hard requirement.
public struct Config: Codable, Sendable {
    public var pythonPath: String
    public var workerModule: String
    public var modelDir: String
    public var voicesDir: String
    public var outDir: String
    public var idleTimeoutS: Double
    public var wavFormat: String        // "s16" | "f32"

    public init(
        pythonPath: String,
        workerModule: String = "vibevoice_mlx.worker",
        modelDir: String = Paths.modelDir.path,
        voicesDir: String = Paths.voicesDir.path,
        outDir: String = Paths.outDir.path,
        idleTimeoutS: Double = 3600,
        wavFormat: String = "s16"
    ) {
        self.pythonPath = pythonPath
        self.workerModule = workerModule
        self.modelDir = modelDir
        self.voicesDir = voicesDir
        self.outDir = outDir
        self.idleTimeoutS = idleTimeoutS
        self.wavFormat = wavFormat
    }

    /// Load config.json, apply env overrides (AUDIO_NOW_IDLE_SECS,
    /// AUDIO_NOW_WORKER_CMD for tests).
    public static func load() throws -> Config {
        let url = URL(fileURLWithPath: Paths.configPath)
        var cfg: Config
        if let data = try? Data(contentsOf: url) {
            do {
                cfg = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                throw AudioNowError.badRequest(
                    "config.json is invalid (\(error)) — fix or delete \(Paths.configPath)")
            }
        } else {
            throw AudioNowError.badRequest(
                "missing \(Paths.configPath) — run `make install` in audio-now/ "
                + "(it records the python venv + model paths)")
        }
        if let idle = ProcessInfo.processInfo.environment["AUDIO_NOW_IDLE_SECS"],
           let v = Double(idle) {
            cfg.idleTimeoutS = v
        }
        return cfg
    }

    /// Worker argv. AUDIO_NOW_WORKER_CMD substitutes the whole command —
    /// how tests run fakeworker under the real daemon. JSON-array form
    /// (`["…/fake worker","--flag"]`) survives paths with spaces;
    /// otherwise it is whitespace-split.
    public var workerCommand: [String] {
        if let raw = ProcessInfo.processInfo.environment["AUDIO_NOW_WORKER_CMD"] {
            if raw.hasPrefix("["),
               let data = raw.data(using: .utf8),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                return arr
            }
            return raw.split(separator: " ").map(String.init)
        }
        return [pythonPath, "-m", workerModule,
                "--model", modelDir, "--voices-dir", voicesDir]
    }
}
