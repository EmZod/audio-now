import Foundation

/// Wire messages. Optional-bag Codable structs: every field typed, absent
/// fields omitted on the wire, unknown fields ignored on decode — the
/// forward-compatibility posture both protocols need.

// MARK: - CLI -> daemon

public struct Request: Codable, Sendable {
    public var cmd: String
    public var text: String?
    public var voice: String?
    public var voices: [String: String]?   // multi-speaker: script number -> voice
    public var seed: Int?
    public var out: String?
    public var format: String?             // wav: "s16" | "f32"
    public var detach: Bool?
    public var playback: Bool?             // false = render-only job
    public var scope: String?              // stop: "all" | "current"
    public var job: String?                // wait / stop
    public var name: String?               // voice_add
    public var wav: String?                // voice_add clip path

    public init(cmd: String) { self.cmd = cmd }
}

// MARK: - daemon -> CLI

public struct Event: Codable, Sendable {
    public var event: String
    public var job: String?
    public var position: Int?
    public var voice: String?
    public var ms: Int?                    // ttfa
    public var chunk: Int?
    public var chunks: Int?
    public var generatedS: Double?
    public var playedS: Double?
    public var rtf: Double?
    public var reason: String?             // done: completed | stopped
    public var wav: String?
    public var durationS: Double?
    public var underruns: Int?
    public var tokens: Int?
    public var warnings: [String]?
    public var jobs: [String]?             // stopped
    public var queueCleared: Int?
    public var code: String?               // error code
    public var message: String?
    public var hint: String?
    public var voices: [VoiceInfo]?
    public var loadMs: Int?                // ready (warm)
    public var wasWarm: Bool?
    public var status: StatusInfo?
    public var pid: Int?                   // pong
    public var version: String?

    public init(event: String) { self.event = event }

    enum CodingKeys: String, CodingKey {
        case event, job, position, voice, ms, chunk, chunks
        case generatedS = "generated_s"
        case playedS = "played_s"
        case rtf, reason, wav
        case durationS = "duration_s"
        case underruns, tokens, warnings, jobs
        case queueCleared = "queue_cleared"
        case code, message, hint, voices
        case loadMs = "load_ms"
        case wasWarm = "was_warm"
        case status, pid, version
    }

    public static func error(job: String? = nil, code: String,
                             message: String, hint: String? = nil) -> Event {
        var e = Event(event: "error")
        e.job = job; e.code = code; e.message = message; e.hint = hint
        return e
    }
}

public struct VoiceInfo: Codable, Sendable {
    public var id: String
    public var isDefault: Bool?
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case id, notes
        case isDefault = "default"
    }

    public init(id: String, isDefault: Bool? = nil, notes: String? = nil) {
        self.id = id; self.isDefault = isDefault; self.notes = notes
    }
}

public struct StatusInfo: Codable, Sendable {
    public struct DaemonInfo: Codable, Sendable {
        public var pid: Int
        public var uptimeS: Double
        public var idleExitInS: Double?
        enum CodingKeys: String, CodingKey {
            case pid
            case uptimeS = "uptime_s"
            case idleExitInS = "idle_exit_in_s"
        }
        public init(pid: Int, uptimeS: Double, idleExitInS: Double?) {
            self.pid = pid; self.uptimeS = uptimeS; self.idleExitInS = idleExitInS
        }
    }
    public struct WorkerInfo: Codable, Sendable {
        public var state: String            // cold | warming | ready
        public var pid: Int?
        public var warmingS: Double?
        enum CodingKeys: String, CodingKey {
            case state, pid
            case warmingS = "warming_s"
        }
        public init(state: String, pid: Int?, warmingS: Double?) {
            self.state = state; self.pid = pid; self.warmingS = warmingS
        }
    }
    public struct ActiveInfo: Codable, Sendable {
        public var job: String
        public var kind: String
        public var generatedS: Double
        public var playedS: Double
        public var chunk: Int?
        public var chunks: Int?
        enum CodingKeys: String, CodingKey {
            case job, kind, chunk, chunks
            case generatedS = "generated_s"
            case playedS = "played_s"
        }
        public init(job: String, kind: String, generatedS: Double,
                    playedS: Double, chunk: Int?, chunks: Int?) {
            self.job = job; self.kind = kind; self.generatedS = generatedS
            self.playedS = playedS; self.chunk = chunk; self.chunks = chunks
        }
    }

    public var daemon: DaemonInfo
    public var worker: WorkerInfo
    public var active: ActiveInfo?
    public var queue: [String]
    public var underrunsTotal: Int
    public var expectedTtfsS: Double

    enum CodingKeys: String, CodingKey {
        case daemon, worker, active, queue
        case underrunsTotal = "underruns_total"
        case expectedTtfsS = "expected_ttfs_s"
    }

    public init(daemon: DaemonInfo, worker: WorkerInfo, active: ActiveInfo?,
                queue: [String], underrunsTotal: Int, expectedTtfsS: Double) {
        self.daemon = daemon; self.worker = worker; self.active = active
        self.queue = queue; self.underrunsTotal = underrunsTotal
        self.expectedTtfsS = expectedTtfsS
    }
}

// MARK: - daemon -> worker (stdin NDJSON)

public struct WorkerCommand: Codable, Sendable {
    public var op: String
    public var job: String?
    public var text: String?
    public var voice: String?
    public var voices: [String: String]?
    public var seed: Int?
    public var name: String?
    public var wav: String?

    public init(op: String) { self.op = op }
}

// MARK: - worker -> daemon ('J' frames)

public struct WorkerEvent: Codable, Sendable {
    public var event: String
    public var job: String?
    public var model: String?
    public var voice: String?
    public var loadMs: Int?
    public var voices: [VoiceInfo]?
    public var chunk: Int?
    public var chunks: Int?
    public var generatedS: Double?
    public var rtf: Double?
    public var tokens: Int?
    public var warnings: [String]?
    public var message: String?
    public var name: String?
    public var durationS: Double?

    enum CodingKeys: String, CodingKey {
        case event, job, model, voice, voices, chunk, chunks, rtf, tokens
        case warnings, message, name
        case loadMs = "load_ms"
        case generatedS = "generated_s"
        case durationS = "duration_s"
    }

    /// After these, the reader must seal the wav before forwarding.
    public var isTerminalForJob: Bool {
        ["done", "cancelled", "error", "voice_added"].contains(event)
    }
}

// MARK: - JSON helpers

public enum Wire {
    /// Single-line JSON (NDJSON safe): no pretty printing, stable key order.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(line.utf8))
    }
}
