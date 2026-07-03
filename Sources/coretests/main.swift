// Framework-free test runner (the CLT toolchain ships no Testing/XCTest).
// `make test` runs this; any failed check prints FAIL and exits 1.
import AudioNowCore
import CoreGraphics
import CoreText
import Foundation

setbuf(stdout, nil)   // crash-proof output ordering

nonisolated(unsafe) var failures = 0

func check(_ cond: Bool, _ label: String,
           file: String = #fileID, line: Int = #line) {
    if cond {
        print("  ok  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)  (\(file):\(line))")
    }
}

func section(_ name: String) { print("[\(name)]") }

// MARK: framing

section("framing")
do {
    let frames: [Framing.Frame] = [
        .json(Data(#"{"event":"ready"}"#.utf8)),
        .pcm(Data((0..<12_800).map { UInt8($0 % 251) })),
        .json(Data("{}".utf8)),
    ]
    var wire = Data()
    for f in frames { wire.append(Framing.encode(f)) }
    var parser = Framing.Parser()
    var got: [Framing.Frame] = []
    var idx = wire.startIndex
    for size in [1, 3, 5000, 2, 9999, wire.count] {
        let end = wire.index(idx, offsetBy: size,
                             limitedBy: wire.endIndex) ?? wire.endIndex
        got += try parser.feed(wire.subdata(in: idx..<end))
        idx = end
        if idx == wire.endIndex { break }
    }
    check(got == frames, "incremental round-trip across odd slice sizes")
} catch {
    check(false, "framing threw: \(error)")
}

do {
    var parser = Framing.Parser()
    var bad = Data([UInt8(ascii: "A")])
    var len = UInt32(1 << 20).littleEndian
    withUnsafeBytes(of: &len) { bad.append(contentsOf: $0) }
    var threw = false
    do { _ = try parser.feed(bad) } catch { threw = true }
    check(threw, "oversized frame rejected")
}

// MARK: line splitter

section("ndjson")
do {
    var s = LineSplitter()
    check(s.feed(Data("hel".utf8)) == [], "partial line held")
    check(s.feed(Data("lo\nwor".utf8)) == ["hello"], "line completed")
    check(s.feed(Data("ld\n\n".utf8)) == ["world"], "blank lines dropped")
}

// MARK: messages

section("messages")
do {
    var e = Event(event: "done")
    e.generatedS = 1.5
    e.queueCleared = 2
    let line = try Wire.encode(e)
    check(line.contains("\"generated_s\":1.5"), "snake_case generated_s")
    check(line.contains("\"queue_cleared\":2"), "snake_case queue_cleared")
    check(!line.contains("generatedS"), "no camelCase leaks")

    let req = try Wire.decode(
        Request.self, from: #"{"cmd":"say","text":"hi","future_flag":true}"#)
    check(req.cmd == "say" && req.text == "hi", "unknown fields ignored")

    let done = try Wire.decode(WorkerEvent.self,
                               from: #"{"event":"done","job":"j-1"}"#)
    check(done.isTerminalForJob, "done is terminal")
    let prog = try Wire.decode(WorkerEvent.self, from: #"{"event":"progress"}"#)
    check(!prog.isTerminalForJob, "progress is not terminal")
} catch {
    check(false, "messages threw: \(error)")
}

// MARK: ring buffer SPSC stress

section("ring buffer")
do {
    let ring = PCMRingBuffer(seconds: 0.05)   // tiny: forces wrap + backpressure
    let total = 300_000
    let producer = Thread {
        var value: Float = 0
        var chunk = [Float](repeating: 0, count: 733)
        var sent = 0
        while sent < total {
            let n = min(chunk.count, total - sent)
            for i in 0..<n { chunk[i] = value; value += 1 }
            chunk.withUnsafeBufferPointer { buf in
                while !ring.write(buf.baseAddress!, count: n) {
                    Thread.sleep(forTimeInterval: 0.0002)
                }
            }
            sent += n
        }
    }
    producer.start()
    var expected: Float = 0
    var out = [Float](repeating: 0, count: 1024)
    var received = 0
    var intact = true
    let deadline = Date().addingTimeInterval(20)
    while received < total && Date() < deadline {
        let n = out.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: $0.count)
        }
        if n == 0 { usleep(200); continue }
        for i in 0..<n {
            if out[i] != expected { intact = false }
            expected += 1
        }
        received += n
    }
    check(received == total, "all \(total) samples delivered under contention")
    check(intact, "no loss, duplication, or reordering")
}

// MARK: wav writer

section("wav writer")
do {
    let path = NSTemporaryDirectory() + "audio-now-test-\(UUID().uuidString).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let w = try WavWriter(path: path, format: .s16)
    let samples = [Float](repeating: 0.5, count: 24_000)
    samples.withUnsafeBufferPointer { w.append($0.baseAddress!, count: $0.count) }
    check(abs(w.durationS - 1.0) < 1e-9, "duration tracks samples")
    w.finalize()

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    check(data.count == 44 + 48_000, "s16 file size")
    check(String(decoding: data[0..<4], as: UTF8.self) == "RIFF"
          && String(decoding: data[8..<12], as: UTF8.self) == "WAVE",
          "RIFF/WAVE magic")
    check(data[20] == 1 && data[22] == 1, "PCM mono fmt")
    let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    check(UInt32(littleEndian: rate) == 24_000, "24kHz rate")
    let dataLen = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    check(UInt32(littleEndian: dataLen) == 48_000, "patched data size")
    let first = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
    check(Int16(littleEndian: first) > 16_000, "0.5f -> positive s16")
} catch {
    check(false, "wav writer threw: \(error)")
}

do {
    let path = NSTemporaryDirectory() + "audio-now-test-\(UUID().uuidString).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let w = try WavWriter(path: path, format: .f32)
    let samples: [Float] = [0.25, -0.25]
    samples.withUnsafeBufferPointer { w.append($0.baseAddress!, count: 2) }
    w.finalize()
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    check(data.count == 44 + 8 && data[20] == 3, "f32 format header")
    let v = data[44..<48].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    check(v == 0.25, "f32 sample intact")
} catch {
    check(false, "wav f32 threw: \(error)")
}

// MARK: voice catalog

section("voice catalog")
do {
    let dir = NSTemporaryDirectory() + "audio-now-voices-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: dir + "/b.safetensors", contents: Data())
    FileManager.default.createFile(atPath: dir + "/a.safetensors", contents: Data())
    try Data(#"{"default":"b","notes":{"a":"noisy"}}"#.utf8)
        .write(to: URL(fileURLWithPath: dir + "/voices.json"))
    let voices = VoiceCatalog.list(dir: dir)
    check(voices.map(\.id) == ["a", "b"], "sorted listing")
    check(voices.first { $0.id == "b" }?.isDefault == true, "manifest default")
    check(voices.first { $0.id == "a" }?.notes == "noisy", "notes carried")
} catch {
    check(false, "voice catalog threw: \(error)")
}

// MARK: ingest

section("ingest: classify")
do {
    let dir = NSTemporaryDirectory() + "audio-now-ingest-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let md = dir + "/notes.md"
    try Data("# Hi\nBody text here.\n".utf8).write(to: URL(fileURLWithPath: md))

    if case .literal = try Ingest.classify("hello world") {
        check(true, "plain speech stays literal")
    } else { check(false, "plain speech stays literal") }

    if case .file(let p, let ext) = try Ingest.classify(md) {
        check(p == md && ext == "md", "existing .md path detected")
    } else { check(false, "existing .md path detected") }

    if case .literal = try Ingest.classify("saved it to notes.txt") {
        check(true, "sentence ending in .txt stays speech")
    } else { check(false, "sentence ending in .txt stays speech") }

    var threw = false
    do { _ = try Ingest.classify("missing_file.md") } catch { threw = true }
    check(threw, "missing single-token .md path is a caught typo")

    threw = false
    do { _ = try Ingest.classify(dir) } catch let e as IngestError {
        if case .isDirectory = e { threw = true }
    }
    check(threw, "directory rejected")

    let rst = dir + "/doc.rst"
    try Data("hi".utf8).write(to: URL(fileURLWithPath: rst))
    threw = false
    do { _ = try Ingest.classify(rst) } catch let e as IngestError {
        if case .unsupported = e { threw = true }
    }
    check(threw, "unsupported extension teaches conversion")
} catch {
    check(false, "classify threw: \(error)")
}

section("ingest: markdown")
do {
    let src = """
    # Overview

    This is **bold** and [a link](https://example.com/x) and `code`.
    See https://github.com/anthropics/claude for more.

    | voice | quality |
    |-------|---------|
    | carter | high |
    | maya | mid |

    - first item
    - second item

    ```swift
    let x = 1
    ```

    Energy is $E=mc^2$ but lunch costs $5 and $10 together.

    $$
    \\int_0^1 x dx
    $$

    Footnote[^1] and citation [12] vanish.
    """
    let (text, findings) = MarkdownSpeech.transform(src)
    check(text.contains("Overview."), "header becomes a short sentence")
    check(text.contains("bold") && !text.contains("**"), "emphasis stripped")
    check(text.contains("a link") && !text.contains("example.com/x"),
          "link keeps its text, loses its url")
    check(text.contains("github.com") && !text.contains("https://"),
          "bare url shortened to host")
    check(text.contains("carter: high"), "2-col table reads as key: value")
    check(text.contains("first item.") && !text.contains("- first"),
          "list markers dropped, items sentence-ized")
    check(text.contains("Code omitted.") && !text.contains("let x = 1"),
          "fenced code omitted with spoken marker")
    check(text.contains("Energy is formula"), "inline math replaced")
    check(text.contains("$5 and $10"), "currency survives the math pass")
    check(text.contains("Formula omitted."), "display math omitted")
    check(!text.contains("[^1]") && !text.contains("[12]"),
          "footnotes and citations stripped")

    func f(_ c: String) -> IngestFinding? { findings.first { $0.category == c } }
    check(f("table")?.score == 1, "2-col table scores 1")
    check(f("code_block")?.score == 2, "code block scores 2")
    check((f("formula")?.score ?? 0) >= 3, "formulas scored (inline + display)")
    check(f("bare_url") != nil && f("bare_url")!.score == 0,
          "bare url finding is warn-only")
    check((f("table")?.lines.first ?? 0) > 0, "findings carry source lines")
}

section("ingest: complexity policy")
do {
    let wide = """
    | a | b | c |
    |---|---|---|
    | one | two | three |
    """
    let one = MarkdownSpeech.transform(wide)
    check(one.findings.first { $0.category == "table" }?.score == 3,
          "wide table scores 3")
    check(one.text.contains("a one, b two, c three."),
          "wide table linearized with headers")

    let heavy = Array(repeating: wide, count: 4)
        .joined(separator: "\n\nplain prose between them\n\n")
    let r = MarkdownSpeech.transform(heavy)
    let total = r.findings.reduce(0) { $0 + $1.score }
    check(total >= Ingest.refuseThreshold,
          "four wide tables cross the refusal threshold")
}

section("ingest: txt scan")
do {
    let dir = NSTemporaryDirectory() + "audio-now-ingest-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let txt = dir + "/data.txt"
    try Data(("Revenue was 1234567 in 2025 and 2345678 in 2026 "
              + "with 99 units at 1111 each.\n").utf8)
        .write(to: URL(fileURLWithPath: txt))
    let r = try Ingest.file(atPath: txt, ext: "txt")
    check(r.kind == .txt, "txt kind")
    check(r.findings.contains { $0.category == "numbers" }, "digit-heavy flagged")
    check(r.text.contains("1234567"), "txt content passes through untouched")
    check(r.findings.allSatisfy { $0.score == 0 }, "txt findings never score")
} catch {
    check(false, "txt scan threw: \(error)")
}

section("ingest: pdf")
do {
    let dir = NSTemporaryDirectory() + "audio-now-ingest-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    func makePDF(_ path: String, pages: [String]) {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(
                url: URL(fileURLWithPath: path) as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for t in pages {
            ctx.beginPDFPage(nil)
            if !t.isEmpty {
                let attr = NSAttributedString(string: t, attributes:
                    [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let fs = CTFramesetterCreateWithAttributedString(attr)
                let box = CGPath(rect: mediaBox.insetBy(dx: 50, dy: 50),
                                 transform: nil)
                let frame = CTFramesetterCreateFrame(
                    fs, CFRange(location: 0, length: 0), box, nil)
                CTFrameDraw(frame, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    let good = dir + "/doc.pdf"
    makePDF(good, pages: ["hello from the pdf fixture built by "
                          + "coretests for extraction checks"])
    let r = try Ingest.file(atPath: good, ext: "pdf")
    check(r.kind == .pdf, "pdf kind")
    check(r.text.contains("hello from the pdf fixture"), "pdf text extracted")

    let blank = dir + "/blank.pdf"
    makePDF(blank, pages: [""])
    var threw = false
    do { _ = try Ingest.file(atPath: blank, ext: "pdf") } catch { threw = true }
    check(threw, "image-only pdf errors with teaching (no extractable text)")

    check(PDFText.reflow("compu-\ntation is neat") == "computation is neat",
          "end-of-line hyphenation healed")
    check(PDFText.reflow("line one\nline two") == "line one line two",
          "hard-wrapped lines rejoined")
    check(!PDFText.reflow("body text\nPage 3\nmore text").contains("Page 3"),
          "page-number furniture dropped")

    let hdr = "ACME Corp — Confidential"
    let paged = (1...4).map { "\(hdr)\nbody of page \($0) with words" }
    let swept = PDFText.dropRunningHeaders(paged)
    check(!swept.joined().contains(hdr) && swept[2].contains("body of page 3"),
          "running headers dropped, body kept")
} catch {
    check(false, "pdf threw: \(error)")
}

// MARK: verdict

if failures > 0 {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
print("\nALL CORE TESTS PASSED")
