// Fake worker: speaks the audio-now worker protocol, emits sine PCM.
// Lets the daemon be developed/drilled without the 7B model:
//   --load-ms 300 --ttfa-ms 200 --rtf 4 --crash-after-frames N --ignore-cancel
import AudioNowCore
import Foundation
import Synchronization

let args = CommandLine.arguments
func flag(_ name: String) -> Bool { args.contains(name) }
func opt(_ name: String, _ def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count,
          let v = Int(args[i + 1]) else { return def }
    return v
}

let loadMs = opt("--load-ms", 300)
let ttfaMs = opt("--ttfa-ms", 200)
let rtf = Double(opt("--rtf-x100", 400)) / 100.0
let crashAfter = opt("--crash-after-frames", -1)
let ignoreCancel = flag("--ignore-cancel")
// Silent by default: lifecycle drills shouldn't beep at whoever is nearby.
// --audible restores the tone for by-ear checks.
let amplitude: Float = flag("--audible") ? 0.2 : 0.0

let out = FileHandle.standardOutput
let outLock = NSLock()

func emit(_ frame: Framing.Frame) {
    outLock.lock()
    out.write(Framing.encode(frame))
    outLock.unlock()
}

func emitJSON(_ s: String) { emit(.json(Data(s.utf8))) }

let cancelled = Atomic<Bool>(false)
let jobs = DispatchQueue(label: "fakeworker.jobs")

// stdin control thread (main thread here): dispatch generates, flip cancel.
Thread.sleep(forTimeInterval: Double(loadMs) / 1000)
emitJSON(#"{"event":"ready","model":"fakeworker","load_ms":\#(loadMs)}"#)

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let op = obj["op"] as? String else { continue }
    switch op {
    case "generate":
        let job = obj["job"] as? String ?? "?"
        let text = obj["text"] as? String ?? ""
        cancelled.store(false, ordering: .relaxed)
        jobs.async {
            let words = text.split { $0.isWhitespace }.count
            let durationS = max(0.5, Double(words) / 2.4)
            let frame = 3_200
            let totalFrames = Int(durationS * 24_000) / frame
            emitJSON(#"{"event":"started","job":"\#(job)","chunks":1}"#)
            emitJSON(#"{"event":"pcm_begin","job":"\#(job)","sample_rate":24000,"channels":1,"format":"f32"}"#)
            Thread.sleep(forTimeInterval: Double(ttfaMs) / 1000)
            var samples = [Float](repeating: 0, count: frame)
            var phase = 0.0
            for i in 0..<totalFrames {
                if crashAfter >= 0 && i >= crashAfter {
                    FileHandle.standardError.write(Data("fakeworker: crashing\n".utf8))
                    exit(9)
                }
                if !ignoreCancel && cancelled.load(ordering: .relaxed) {
                    emitJSON(#"{"event":"cancelled","job":"\#(job)","generated_s":\#(Double(i * frame) / 24_000)}"#)
                    return
                }
                for j in 0..<frame {
                    phase += 2.0 * .pi * 330.0 / 24_000
                    samples[j] = Float(sin(phase)) * amplitude
                }
                samples.withUnsafeBufferPointer { buf in
                    emit(.pcm(Data(bytes: buf.baseAddress!, count: frame * 4)))
                }
                Thread.sleep(forTimeInterval: (Double(frame) / 24_000) / rtf)
            }
            let gen = Double(totalFrames * frame) / 24_000
            emitJSON(#"{"event":"done","job":"\#(job)","generated_s":\#(gen),"tokens":\#(totalFrames)}"#)
        }
    case "cancel":
        cancelled.store(true, ordering: .relaxed)
    case "list_voices":
        emitJSON(#"{"event":"voices","voices":[{"id":"fake"}]}"#)
    case "shutdown":
        exit(0)
    default:
        continue
    }
}
// stdin EOF: daemon died — exit (orphan contract).
exit(0)
