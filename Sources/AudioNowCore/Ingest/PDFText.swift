import Foundation
import PDFKit

// PDF -> plain text via PDFKit (system framework, no dependencies).
// Extraction flattens layout, so cleanup is conservative: drop page
// furniture, heal end-of-line hyphenation, reflow hard-wrapped lines.
// Tables come out as word soup and cannot be reliably detected here —
// the math/digit scans and --preview are the guardrails for that.

public enum PDFText {

    public static func extract(path: String) throws -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw IngestError.unreadable(path, why: "not a readable PDF")
        }
        if doc.isLocked {
            throw IngestError.unreadable(path, why: "PDF is password-protected")
        }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            pages.append(doc.page(at: i)?.string ?? "")
        }
        let raw = dropRunningHeaders(pages).joined(separator: "\n\n")
        let words = raw.split(whereSeparator: \.isWhitespace).count
        if doc.pageCount == 0 || words < 5 * doc.pageCount {
            throw IngestError.noText(path, why:
                "only \(words) extractable words across \(doc.pageCount) "
                + "page(s) — likely scanned images. OCR it first, or paste "
                + "the text into a .txt/.md file")
        }
        return reflow(raw)
    }

    /// Running headers/footers repeat verbatim on most pages; the listener
    /// would hear them between every page break. Exposed for coretests.
    public static func dropRunningHeaders(_ pages: [String]) -> [String] {
        guard pages.count >= 3 else { return pages }
        var freq: [String: Int] = [:]
        for page in pages {
            let uniq = Set(page.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.count < 100 })
            for l in uniq { freq[l, default: 0] += 1 }
        }
        let cutoff = max(3, pages.count / 2)
        let furniture = Set(freq.filter { $0.value >= cutoff }.keys)
        guard !furniture.isEmpty else { return pages }
        return pages.map { page in
            page.components(separatedBy: "\n").filter {
                !furniture.contains($0.trimmingCharacters(in: .whitespaces))
            }.joined(separator: "\n")
        }
    }

    /// Exposed for coretests.
    public static func reflow(_ raw: String) -> String {
        var kept: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Page numbers: "7", "Page 7", "7 of 12", "vii".
            if t.range(of: #"^(page\s+)?\d{1,4}(\s+of\s+\d{1,4})?$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            if t.count <= 5, !t.isEmpty,
               t.range(of: #"^[ivxlcdm]+$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            kept.append(line)
        }
        var s = kept.joined(separator: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        // "compu-\ntation" -> "computation"
        s = s.replacingOccurrences(of: #"(\p{L})-\n(\p{Ll})"#, with: "$1$2",
                                   options: .regularExpression)
        // Hard-wrapped lines rejoin; blank lines mark real paragraphs.
        s = s.replacingOccurrences(of: #"([^\n])\n(?!\n)"#, with: "$1 ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ",
                                   options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
