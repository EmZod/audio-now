import Foundation

// Markdown -> speakable prose. No parser dependency: a line state machine
// (fences, math blocks, tables, headers, lists) plus inline regex cleanup.
// Everything that cannot sound good is replaced with a spoken marker and
// recorded as a finding so the agent can rewrite it at the source.

public enum MarkdownSpeech {

    public static func transform(_ source: String) -> (text: String, findings: [IngestFinding]) {
        var bag = FindingBag()
        let text = transform(source, bag: &bag)
        return (text, bag.finish())
    }

    static func transform(_ source: String, bag: inout FindingBag) -> String {
        let lines = source.components(separatedBy: "\n")
        var paras: [String] = []
        var current: [String] = []
        var inFence = false, fenceStart = 0
        var inMath = false, mathStart = 0

        func flush() {
            let joined = current.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { paras.append(joined) }
            current = []
        }

        var i = 0
        while i < lines.count {
            let lineNo = i + 1
            var t = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            if inFence {
                if t.hasPrefix("```") || t.hasPrefix("~~~") {
                    inFence = false
                    bag.add(.codeBlock, line: fenceStart, score: 2)
                    paras.append("Code omitted.")
                }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                inFence = true
                fenceStart = lineNo
                continue
            }
            if inMath {
                if t.contains("$$") || t == "\\]" {
                    inMath = false
                    bag.add(.formula, line: mathStart, score: 2)
                    paras.append("Formula omitted.")
                }
                continue
            }
            if t.hasPrefix("$$") {
                flush()
                if t.count > 4 && t.hasSuffix("$$") {   // one-line $$…$$
                    bag.add(.formula, line: lineNo, score: 2)
                    paras.append("Formula omitted.")
                } else {
                    inMath = true
                    mathStart = lineNo
                }
                continue
            }
            if t == "\\[" {
                flush()
                inMath = true
                mathStart = lineNo
                continue
            }

            if t.isEmpty { flush(); continue }

            // Horizontal rules and setext underlines: pure separator lines.
            if t.count >= 3, let first = t.first, "-=_*".contains(first),
               t.allSatisfy({ $0 == first || $0 == " " }) {
                flush()
                continue
            }

            // Pipe tables: a run of |-prefixed lines (with or without the
            // |---| separator row).
            if t.hasPrefix("|") {
                var rows: [String] = [t]
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix("|") else { break }
                    rows.append(next)
                    i += 1
                }
                if rows.count >= 2 {
                    flush()
                    paras.append(linearizeTable(rows, startLine: lineNo, bag: &bag))
                    continue
                }
                // lone |-line: fall through as text (pipes cleaned inline)
            }

            // Blockquote marker(s).
            while t.hasPrefix(">") {
                t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            // ATX header -> its own short sentence.
            if t.hasPrefix("#") {
                let content = t.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    .trimmingCharacters(in: .whitespaces)
                flush()
                let cleaned = cleanInline(content, line: lineNo, bag: &bag)
                if !cleaned.isEmpty { paras.append(ensureSentence(cleaned)) }
                continue
            }

            // Reference-style link definitions: [id]: https://…
            if t.range(of: #"^\[[^\]]{1,60}\]:\s*\S"#,
                       options: .regularExpression) != nil {
                continue
            }

            // List items (bullets, numbers, task boxes) -> one sentence each.
            if let r = t.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#,
                               options: .regularExpression) {
                var item = String(t[r.upperBound...])
                if let box = item.range(of: #"^\[[ xX]\]\s*"#,
                                        options: .regularExpression) {
                    item = String(item[box.upperBound...])
                }
                flush()
                let cleaned = cleanInline(item, line: lineNo, bag: &bag)
                if !cleaned.isEmpty { paras.append(ensureSentence(cleaned)) }
                continue
            }

            current.append(cleanInline(t, line: lineNo, bag: &bag))
        }
        if inFence { bag.add(.codeBlock, line: fenceStart, score: 2)
                     paras.append("Code omitted.") }
        if inMath { bag.add(.formula, line: mathStart, score: 2)
                    paras.append("Formula omitted.") }
        flush()
        return paras.joined(separator: "\n")
    }

    // MARK: tables

    static func splitRow(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { ":- ".contains($0) }
        }
    }

    /// Best-effort spoken form: 2-column tables read as "key: value." pairs;
    /// wider ones as "H1 v1, H2 v2, …" per row. Both are findings — wide
    /// tables score enough that several of them trip the refusal.
    static func linearizeTable(_ rows: [String], startLine: Int,
                               bag: inout FindingBag) -> String {
        var parsed = rows.map(splitRow)
        var header: [String]? = nil
        if parsed.count >= 2, isSeparatorRow(parsed[1]) {
            header = parsed[0]
            parsed.removeSubrange(0...1)
        }
        let cols = max(header?.count ?? 0, parsed.map(\.count).max() ?? 0)
        bag.add(.table, line: startLine, score: cols <= 2 ? 1 : 3)

        var dummy = FindingBag()   // cell cleanup shouldn't double-count
        func clean(_ s: String) -> String { cleanInline(s, line: 0, bag: &dummy) }

        var sentences: [String] = []
        if let h = header, cols > 2 {
            for row in parsed {
                let bits = row.enumerated().compactMap { i, cell -> String? in
                    let c = clean(cell)
                    guard !c.isEmpty else { return nil }
                    let name = i < h.count ? clean(h[i]) : ""
                    return name.isEmpty ? c : "\(name) \(c)"
                }
                if !bits.isEmpty { sentences.append(bits.joined(separator: ", ") + ".") }
            }
        } else {
            for row in parsed {
                let cells = row.map(clean).filter { !$0.isEmpty }
                if cells.count >= 2 {
                    sentences.append("\(cells[0]): "
                        + cells.dropFirst().joined(separator: ", ") + ".")
                } else if let only = cells.first {
                    sentences.append(only + ".")
                }
            }
        }
        return sentences.joined(separator: " ")
    }

    // MARK: inline cleanup

    static func ensureSentence(_ s: String) -> String {
        guard let last = s.last else { return s }
        return ".!?:;,".contains(last) ? s : s + "."
    }

    static func countMatches(_ pattern: String, _ s: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: s,
                                  range: NSRange(s.startIndex..., in: s))
    }

    static func regexReplace(_ s: String, _ pattern: String,
                             _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template,
                               options: .regularExpression)
    }

    static let latexHeads = "frac|sum|int|prod|sqrt|alpha|beta|gamma|delta|"
        + "epsilon|theta|lambda|mu|pi|sigma|phi|omega|infty|partial|nabla|"
        + "times|cdot|leq|geq|neq|approx|hat|bar|vec|mathbb|mathcal|mathrm|"
        + "begin|end|left|right"

    static func cleanInline(_ input: String, line: Int,
                            bag: inout FindingBag) -> String {
        // NBSP (rich-text exports are full of it) defeats \s-based regexes.
        var s = input.replacingOccurrences(of: "\u{00A0}", with: " ")

        // Images -> alt text (finding when the alt is empty: content lost).
        if s.contains("![") {
            let empty = countMatches(#"!\[\s*\]\([^)]*\)"#, s)
            if empty > 0 { bag.add(.image, line: line, score: 0, count: empty) }
            s = regexReplace(s, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        }
        // Links keep their text; autolink brackets drop before URL scan.
        s = regexReplace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        s = regexReplace(s, #"<((?:https?|mailto)[^>]+)>"#, "$1")
        s = shortenURLs(s, line: line, bag: &bag)

        // Inline math: \( … \), $…$ (with a currency guard), LaTeX commands.
        let parens = countMatches(#"\\\(.{1,120}?\\\)"#, s)
        if parens > 0 {
            bag.add(.formula, line: line, score: parens, count: parens)
            s = regexReplace(s, #"\\\(.{1,120}?\\\)"#, "formula")
        }
        s = replaceDollarMath(s, line: line, bag: &bag)
        let latex = countMatches(#"\\(?:\#(latexHeads))\b(?:\{[^}]*\})*"#, s)
        if latex > 0 {
            bag.add(.formula, line: line, score: latex, count: latex)
            s = regexReplace(s, #"\\(?:\#(latexHeads))\b(?:\{[^}]*\})*"#, "formula")
        }

        // Inline code keeps its content (usually a term worth hearing).
        s = regexReplace(s, #"`([^`]+)`"#, "$1")
        // Emphasis markers.
        s = regexReplace(s, #"\*\*\*([^*]+)\*\*\*"#, "$1")
        s = regexReplace(s, #"\*\*([^*]+)\*\*"#, "$1")
        s = regexReplace(s, #"\*([^*\s][^*]*)\*"#, "$1")
        s = regexReplace(s, #"__([^_]+)__"#, "$1")
        s = regexReplace(s, #"(^|[\s(])_([^_]+)_(?=$|[\s).,;:!?])"#, "$1$2")
        s = regexReplace(s, #"~~([^~]+)~~"#, "$1")
        // Footnote markers and numeric citations.
        s = regexReplace(s, #"\[\^[^\]]+\]"#, "")
        s = regexReplace(s, #"\[\d{1,3}(?:,\s*\d{1,3})*\]"#, "")

        // HTML: count content-bearing blocks, then strip all tags/entities.
        let blocks = countMatches(#"<(?:table|pre|iframe|script|style|form)\b"#,
                                  s.lowercased())
        if blocks > 0 { bag.add(.html, line: line, score: blocks, count: blocks) }
        s = regexReplace(s, #"</?[a-zA-Z][^>]{0,120}>"#, " ")
        s = regexReplace(s, #"<!--.*?-->"#, " ")
        for (ent, ch) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                          ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"),
                          ("&mdash;", " — "), ("&hellip;", "…")] {
            s = s.replacingOccurrences(of: ent, with: ch)
        }

        s = stripSymbols(s)
        // Leftover pipes read as pauses, not "vertical bar".
        s = s.replacingOccurrences(of: "|", with: ", ")
        s = regexReplace(s, #"\s+"#, " ")
        s = regexReplace(s, #"\s+([.,;:!?])"#, "$1")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// $…$ becomes "formula" only when the content looks like math —
    /// "$5 and $10" must survive as money.
    static func replaceDollarMath(_ s: String, line: Int,
                                  bag: inout FindingBag) -> String {
        guard s.contains("$") else { return s }
        guard let re = try? NSRegularExpression(pattern: #"\$([^$\n]{1,80}?)\$"#)
        else { return s }
        let ns = s as NSString
        var out = "", last = 0, count = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) {
            m, _, _ in
            guard let m = m else { return }
            let body = ns.substring(with: m.range(at: 1))
            let mathish = body.rangeOfCharacter(
                from: CharacterSet(charactersIn: "\\^_{}=<>")) != nil
                || (body.count <= 3
                    && body.rangeOfCharacter(from: .letters) != nil
                    && body.rangeOfCharacter(from: .decimalDigits) == nil)
            guard mathish else { return }
            out += ns.substring(with: NSRange(location: last,
                                              length: m.range.location - last))
            out += "formula"
            last = m.range.location + m.range.length
            count += 1
        }
        guard count > 0 else { return s }
        out += ns.substring(from: last)
        bag.add(.formula, line: line, score: count, count: count)
        return out
    }

    static func shortenURLs(_ s: String, line: Int,
                            bag: inout FindingBag) -> String {
        guard s.contains("://") || s.lowercased().contains("www.") else { return s }
        guard let re = try? NSRegularExpression(
            pattern: #"(?:https?://|www\.)[^\s<>()\[\]{}"']+"#,
            options: .caseInsensitive) else { return s }
        let ns = s as NSString
        var out = "", last = 0, count = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) {
            m, _, _ in
            guard let m = m else { return }
            var url = ns.substring(with: m.range)
            for scheme in ["https://", "http://"] where
                url.lowercased().hasPrefix(scheme) {
                url = String(url.dropFirst(scheme.count))
            }
            if url.lowercased().hasPrefix("www.") { url = String(url.dropFirst(4)) }
            let host = url.prefix { !"/:?#".contains($0) }
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            out += ns.substring(with: NSRange(location: last,
                                              length: m.range.location - last))
            out += host
            last = m.range.location + m.range.length
            count += 1
        }
        guard count > 0 else { return s }
        out += ns.substring(from: last)
        bag.add(.bareURL, line: line, score: 0, count: count)
        return out
    }

    /// Drop emoji and decoration glyphs the model would mispronounce.
    static func stripSymbols(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { sc in
            if sc.value == 0xFE0F || sc.value == 0x200D { return false }
            if sc.value >= 0x1F000 && sc.properties.isEmoji { return false }
            if sc.properties.isEmojiPresentation { return false }
            return true
        }))
    }
}
