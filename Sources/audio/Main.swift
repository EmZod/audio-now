import ArgumentParser
import AudioNowCore
import Foundation

@main
struct Audio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Local text-to-speech for agents — warm, fast, self-managing.",
        discussion: """
        The daemon starts on demand and exits after an hour of inactivity;
        you never manage it. Voices live in ~/.audio-now/voices.
        """,
        version: audioNowVersion,
        subcommands: [Say.self, Render.self, Stop.self, Wait.self,
                      Status.self, Voices.self, Warm.self,
                      DaemonCmd.self, Tone.self],
        defaultSubcommand: nil)
}

// MARK: - shared CLI plumbing

func stderrPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func absolutize(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return FileManager.default.currentDirectoryPath + "/" + expanded
}

/// Parse repeated --voice values: "carter" (single) or "1=carter" (map).
func parseVoices(_ values: [String]) -> (single: String?, map: [String: String]?) {
    var single: String?
    var map: [String: String] = [:]
    for v in values {
        if let eq = v.firstIndex(of: "=") {
            map[String(v[..<eq])] = String(v[v.index(after: eq)...])
        } else {
            single = v
        }
    }
    return (single, map.isEmpty ? nil : map)
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let m) = self { return m }
        return "error"
    }
}

/// Quote an argument for display in copy-pasteable example commands.
func shellQuote(_ s: String) -> String {
    guard s.contains(where: { " \t\"'$\\".contains($0) }) else { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Parse a file for speech, teaching on failure.
func ingestFileChecked(path: String, ext: String) throws -> IngestResult {
    do { return try Ingest.file(atPath: path, ext: ext) }
    catch let e as IngestError {
        stderrPrint(e.description)
        throw ExitCode(2)
    }
}

/// Refuse/warn/preview policy for file input, shared by say and render.
/// Returns the text to synthesize, or nil when the command is already done
/// (--preview printed). Refusal never touches the daemon — a 7B model is
/// not woken up to say no.
func applyIngestPolicy(_ r: IngestResult, invocation: String,
                       force: Bool, preview: Bool, json: Bool) throws -> String? {
    let refused = r.kind != .txt && !force && r.score >= Ingest.refuseThreshold
    if preview {
        if json {
            print(try Ingest.jsonEvent(r, refused: refused, includeText: true))
        } else {
            print(r.text)
            stderrPrint(Ingest.previewFooter(r, refused: refused))
        }
        return nil
    }
    if json { print(try Ingest.jsonEvent(r, refused: refused)) }
    if refused {
        if json { print(try Ingest.refusalJSON(r)) }
        else { stderrPrint(Ingest.humanReport(r, invocation: invocation)) }
        throw ExitCode(2)
    }
    if !json, let warn = Ingest.warnLine(r, invocation: invocation) {
        stderrPrint(warn)
    }
    return r.text
}

/// Stream events for a job until terminal; returns the terminal event.
/// json=true echoes every raw line to stdout verbatim.
func streamJob(_ client: DaemonClient, json: Bool,
               narrateColdBoot: Bool = true,
               onEvent: (Event) -> Void = { _ in }) throws -> Event {
    var narrated = false
    var sawStart = false
    let began = Date()
    while true {
        guard let (line, ev) = try client.readEvent(timeout: 2.0) else {
            if narrateColdBoot && !sawStart && !narrated && !json
                && Date().timeIntervalSince(began) > 1.5 {
                stderrPrint("… warming the model (cold start, a few seconds)")
                narrated = true
            }
            continue
        }
        if json { print(line) }
        onEvent(ev)
        switch ev.event {
        case "started":
            sawStart = true
        case "done", "error", "stopped", "voice_added", "idle", "ready":
            return ev
        default:
            break
        }
    }
}

func terminalExitCode(_ ev: Event) -> Int32 {
    ev.event == "error" ? 2 : 0
}

func describeError(_ ev: Event) -> String {
    var s = ev.message ?? "unknown error"
    if let code = ev.code { s = "[\(code)] " + s }
    if let hint = ev.hint { s += "\n  hint: \(hint)" }
    return s
}
