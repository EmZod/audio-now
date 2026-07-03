import Foundation

// File ingestion for `say`/`render`: turn a .txt/.md/.pdf into speakable text
// plus structured "this will sound weird" findings. Pure functions — the CLI
// owns policy (refuse/warn/preview), the daemon never sees any of this.

// MARK: - types

public enum SourceKind: String, Sendable {
    case literal, txt, md, pdf
}

public struct IngestFinding: Sendable, Equatable {
    public let category: String   // "table" | "formula" | "code_block" | ...
    public let count: Int
    public let lines: [Int]       // 1-based source lines (empty = whole-file)
    public let score: Int         // severity contributed to the total
    public let hint: String       // the fix, phrased for the agent
}

public struct IngestResult: Sendable {
    public let kind: SourceKind
    public let sourcePath: String
    public let text: String       // what would be spoken
    public let findings: [IngestFinding]
    public var score: Int { findings.reduce(0) { $0 + $1.score } }
    public var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

public enum IngestError: Error, CustomStringConvertible {
    case notFound(String)
    case isDirectory(String)
    case unsupported(String, ext: String)
    case unreadable(String, why: String)
    case noText(String, why: String)

    public var description: String {
        switch self {
        case .notFound(let p):
            return "no such file: \(p)\n  (if you meant speech, quote plain "
                 + "text; readable files: .txt .md .pdf)"
        case .isDirectory(let p):
            return "\(p) is a directory — point at a .txt/.md/.pdf file"
        case .unsupported(let p, let ext):
            return "cannot read .\(ext) aloud: \(p)\n  supported: .txt .md .pdf"
                 + " — convert first (e.g. `textutil -convert txt` for "
                 + "rtf/docx/html)"
        case .unreadable(let p, let why), .noText(let p, let why):
            return "\(p): \(why)"
        }
    }
}

// MARK: - finding taxonomy

enum FindingKind: String, CaseIterable {
    case table, formula, codeBlock = "code_block", bareURL = "bare_url"
    case image, html, numbers

    var noun: (singular: String, plural: String) {
        switch self {
        case .table: return ("table", "tables")
        case .formula: return ("formula", "formulas")
        case .codeBlock: return ("code block", "code blocks")
        case .bareURL: return ("bare link", "bare links")
        case .image: return ("image", "images")
        case .html: return ("HTML block", "HTML blocks")
        case .numbers: return ("digits", "digits")
        }
    }

    var hint: String {
        switch self {
        case .table:
            return "rewrite each as prose sentences (\"X rose to 40 percent…\")"
        case .formula:
            return "write them out in words (\"x squared over two\")"
        case .codeBlock:
            return "spoken as \"Code omitted.\" — summarize in prose if it matters"
        case .bareURL:
            return "spoken as bare domains — replace with descriptive words"
        case .image:
            return "no speech for images; alt text is used when present"
        case .html:
            return "raw HTML is stripped — check nothing important lived there"
        case .numbers:
            return "numerals are spoken poorly — write key figures as words"
        }
    }

    /// What the transform did about it, for the proceed-with-warning line.
    var action: String {
        switch self {
        case .table: return "linearized"
        case .formula: return "spoken as \"formula\""
        case .codeBlock: return "omitted"
        case .bareURL: return "shortened to domains"
        case .image: return "dropped"
        case .html: return "stripped"
        case .numbers: return "left as-is"
        }
    }
}

struct FindingBag {
    private var acc: [FindingKind: (count: Int, lines: [Int], score: Int)] = [:]

    mutating func add(_ kind: FindingKind, line: Int, score: Int, count: Int = 1) {
        var e = acc[kind] ?? (0, [], 0)
        e.count += count
        if line > 0 { e.lines.append(line) }
        e.score += score
        acc[kind] = e
    }

    func finish() -> [IngestFinding] {
        acc.map { kind, e in
            IngestFinding(category: kind.rawValue, count: e.count,
                          lines: e.lines.sorted(), score: e.score,
                          hint: kind.hint)
        }
        .sorted { ($0.score, $0.count) > ($1.score, $1.count) }
    }
}

// MARK: - input classification

public enum ResolvedInput: Sendable {
    case literal(String)
    case file(path: String, ext: String)
}

public enum Ingest {
    public static let supportedExts: Set<String> = ["txt", "text", "md",
                                                    "markdown", "pdf"]
    /// Total complexity at which md/pdf input is refused without --force.
    public static let refuseThreshold = 10

    /// Extension of a *candidate* path: tail after the last dot, only if it
    /// looks like one (short, alphanumeric). "notes.md for details" -> "".
    static func extensionOf(_ s: String) -> String {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return "" }
        let tail = s[s.index(after: dot)...]
        guard !tail.isEmpty, tail.count <= 9,
              tail.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "" }
        return tail.lowercased()
    }

    /// Decide whether a `say` argument is a file to read or literal speech.
    /// Pathish = leading / ~/ ./ ../ or a supported extension. Pathish +
    /// missing is an error only when it cannot be a sentence (single token
    /// or explicit path prefix) — "saved it to notes.txt" stays speech,
    /// "notes.md" that doesn't exist is a caught typo, never spoken aloud.
    public static func classify(_ arg: String) throws -> ResolvedInput {
        let hasPrefix = arg.hasPrefix("/") || arg.hasPrefix("~/")
                     || arg.hasPrefix("./") || arg.hasPrefix("../")
        let ext = extensionOf(arg)
        guard hasPrefix || supportedExts.contains(ext) else {
            return .literal(arg)
        }
        let expanded = (arg as NSString).expandingTildeInPath
        let abs = ((expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded)
            as NSString).standardizingPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) {
            if isDir.boolValue { throw IngestError.isDirectory(abs) }
            guard supportedExts.contains(ext) else {
                throw IngestError.unsupported(abs, ext: ext.isEmpty ? "?" : ext)
            }
            return .file(path: abs, ext: ext)
        }
        if hasPrefix || !arg.contains(where: \.isWhitespace) {
            throw IngestError.notFound(abs)
        }
        return .literal(arg)
    }

    // MARK: ingestion

    public static func file(atPath abs: String, ext: String) throws -> IngestResult {
        var bag = FindingBag()
        let kind: SourceKind
        let text: String
        switch ext {
        case "md", "markdown":
            kind = .md
            text = MarkdownSpeech.transform(try readUTF8(abs), bag: &bag)
        case "pdf":
            kind = .pdf
            text = try PDFText.extract(path: abs)
        default:
            kind = .txt
            text = try readUTF8(abs)
            scanPlainTables(text, bag: &bag)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestError.noText(abs, why: "nothing speakable after parsing")
        }
        scanCommon(text, bag: &bag)
        return IngestResult(kind: kind, sourcePath: abs, text: text,
                            findings: bag.finish())
    }

    static func readUTF8(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw IngestError.unreadable(path, why: "cannot read file")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Scans that apply to every source kind, run on the *spoken* text:
    /// digit density and unicode math symbols (the pdf/txt formula signal).
    static func scanCommon(_ text: String, bag: inout FindingBag) {
        let digits = text.filter(\.isNumber).count
        if digits > 20 {
            bag.add(.numbers, line: 0, score: 0, count: digits)
        }
        let math = text.unicodeScalars.filter {
            (0x2200...0x22FF).contains($0.value)      // ∀∑∫≈≠≤…
            || (0x27C0...0x27EF).contains($0.value)   // misc math
            || $0.value == 0x221A || $0.value == 0x00B1
        }.count
        if math >= 4 {
            bag.add(.formula, line: 0, score: min(6, math / 4), count: math)
        }
    }

    /// Pipe-table detection for .txt (warn-only there — txt is never refused).
    static func scanPlainTables(_ text: String, bag: inout FindingBag) {
        var runStart = 0, runLen = 0, lineNo = 0
        for line in text.components(separatedBy: "\n") {
            lineNo += 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                if runLen == 0 { runStart = lineNo }
                runLen += 1
            } else {
                if runLen >= 2 { bag.add(.table, line: runStart, score: 1) }
                runLen = 0
            }
        }
        if runLen >= 2 { bag.add(.table, line: runStart, score: 1) }
    }

    // MARK: - reporting (human + json)

    static func lineList(_ lines: [Int], max: Int = 4) -> String {
        guard !lines.isEmpty else { return "" }
        let shown = lines.prefix(max).map(String.init).joined(separator: ", ")
        let more = lines.count - min(lines.count, max)
        return "line\(lines.count == 1 ? "" : "s") " + shown
             + (more > 0 ? " +\(more)" : "")
    }

    static func counted(_ f: IngestFinding) -> String {
        guard let kind = FindingKind(rawValue: f.category) else { return f.category }
        if kind == .numbers { return "digit-heavy (\(f.count) digits)" }
        return "\(f.count) \(f.count == 1 ? kind.noun.singular : kind.noun.plural)"
    }

    /// Aligned "  4 tables   lines 23, 88 +2  -> hint" rows.
    static func findingRows(_ r: IngestResult) -> [String] {
        let width = max(12, r.findings.map { counted($0).count }.max() ?? 0)
        let locWidth = max(18, r.findings.map { lineList($0.lines).count }.max() ?? 0)
        return r.findings.map { f in
            let label = counted(f).padding(toLength: width, withPad: " ",
                                           startingAt: 0)
            let loc = lineList(f.lines).padding(toLength: locWidth,
                                                withPad: " ", startingAt: 0)
            return "  \(label)  \(loc)  -> \(f.hint)"
        }
    }

    /// The refusal block: what scored, where, and the exact next commands.
    public static func humanReport(_ r: IngestResult, invocation: String) -> String {
        let name = (r.sourcePath as NSString).lastPathComponent
        var out = ["\(name): heavy non-prose formatting — this will sound bad "
                 + "as speech (complexity \(r.score), refuses at \(refuseThreshold))"]
        out += findingRows(r)
        out.append("Rewrite those sections for the ear in a copy, then retry. Or:")
        out.append("  \(invocation) --preview     show exactly what would be spoken")
        out.append("  \(invocation) --force       speak the best-effort version anyway")
        return out.joined(separator: "\n")
    }

    /// stderr footer for --preview (the text itself goes to stdout).
    public static func previewFooter(_ r: IngestResult, refused: Bool) -> String {
        let secs = Int(Double(r.words) / 2.4)
        let head = "— \(r.words) words, ~\(secs)s of speech"
        if r.findings.isEmpty {
            return head + " — clean, no formatting concerns"
        }
        var out = [head + " — complexity \(r.score) (refuses at \(refuseThreshold))"
                 + (refused ? " — WOULD BE REFUSED without --force" : "")]
        out += findingRows(r)
        return out.joined(separator: "\n")
    }

    /// One-line stderr note when proceeding with a transformed file.
    /// Only markdown gets the action verbs — pdf/txt content is scanned,
    /// not rewritten, so "linearized"/"omitted" would be a lie there.
    public static func warnLine(_ r: IngestResult, invocation: String) -> String? {
        guard !r.findings.isEmpty else { return nil }
        let bits = r.findings.compactMap { f -> String? in
            guard let kind = FindingKind(rawValue: f.category) else { return nil }
            if kind == .numbers || r.kind != .md { return counted(f) }
            return "\(counted(f)) \(kind.action)"
        }
        let name = (r.sourcePath as NSString).lastPathComponent
        return "⚠ \(name): " + bits.joined(separator: ", ")
             + " — `\(invocation) --preview` shows the spoken text"
    }

    /// NDJSON line describing the ingestion (emitted by the CLI in --json mode).
    public static func jsonEvent(_ r: IngestResult, refused: Bool,
                                 includeText: Bool = false) throws -> String {
        let findings: [[String: Any]] = r.findings.map {
            ["category": $0.category, "count": $0.count, "lines": $0.lines,
             "score": $0.score, "hint": $0.hint]
        }
        var obj: [String: Any] = [
            "event": "ingest", "source": r.sourcePath,
            "kind": r.kind.rawValue, "words": r.words, "score": r.score,
            "refuse_at": refuseThreshold, "refused": refused,
            "findings": findings,
        ]
        if includeText { obj["text"] = r.text }
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// NDJSON error line for a refusal (mirrors the daemon's error shape).
    public static func refusalJSON(_ r: IngestResult) throws -> String {
        let what = r.findings.filter { $0.score > 0 }.map(counted).joined(separator: ", ")
        let obj: [String: Any] = [
            "event": "error", "code": "complex_formatting",
            "message": "\((r.sourcePath as NSString).lastPathComponent) scored "
                     + "\(r.score) (refuses at \(refuseThreshold)): \(what)",
            "hint": "rewrite the flagged sections as prose for the ear, or "
                  + "rerun with --force (best-effort) / --preview (inspect)",
        ]
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
