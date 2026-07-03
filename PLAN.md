# audio-now — local TTS built for agents

## Context

The `speak` skill (built in a few hours last year) wraps a local TTS for agents. The user wants it rebuilt properly as **audio-now**, invocation command **`audio`**: extremely fast and efficient, near-instant cold boot, near-zero idle footprint *while still being warm when an agent reaches for it out of the blue*, graceful auto-shutdown after 1h idle, written in a typed language, with materially better TTFS than this week's `serve.py` (0.69–0.90s warm) — and an interface designed for agents as the primary user ("the primitive is the product").

### Review of what exists (three generations, each half right)

| | engine | quality | warm TTFS | cold boot | lifecycle | interface |
|---|---|---|---|---|---|---|
| **speak** (TS/Bun, 2025) | chatterbox-turbo 8-bit | mid | 3–8s (!) | 4–8s | daemon, 1h idle | 20+ flags/commands, feature-heavy |
| **speakturbo** (Rust CLI + Py daemon) | pocket-tts (~100MB) | low, 8 stock voices, no cloning | ~90ms | 2–5s | HTTP :7125, 1h idle | minimal, clean |
| **serve.py** (this week) | VibeVoice 7B 4-bit MLX | best-in-class + voice cloning | 0.69–0.90s | ~45–60s | none: no CLI, no idle shutdown, `pkill` to stop, no stop/status during a job | raw HTTP |

The user already discovered the right shape once: **speakturbo** (tiny typed CLI + warm daemon + 1h idle). Its flaw is the toy engine. `speak`'s flaw is the wrapper: in-process playback, warm TTFS of seconds, and a "Common Errors" table that documents design bugs instead of fixing them (relative paths fail, dirs not auto-created, stale daemons, glob-order concat traps). `serve.py` is the right engine with no product around it — and its single-threaded HTTP means a 55-min job can't even be stopped (we hit this yesterday; killing it took `pkill`).

**audio-now = speakturbo's architecture × serve.py's engine × a smaller primitive surface than speak's** — in Swift (6.2 is installed; no Go on the box; MLX pins us to Apple Silicon anyway, and native AVAudioEngine playback permanently kills the GIL-starvation bug class we fought this week).

### Design doctrine applied

- **Goedecke**: minimize stateful components (durable state lives *only* on disk: weights snapshot, voices, wavs, config; daemon state is ephemeral and rebuildable by restart); boring components (Unix socket, NDJSON, pipes, stdio); every automation gets a killswitch (`audio stop`, `audio daemon stop`); log unhappy paths aggressively; the hot path is the PCM stream — design that first; complex evolves from simple.
- **"The primitive is the product"**: capabilities, not features. `speak`'s batch/concat/estimate/resume features are *composition an agent can do itself* (shell loops, `ffmpeg`, arithmetic). The primitive set is 6 verbs. Constraints are explicit and errors teach the correct next call.

---

## Architecture — three processes, strict ownership

```
 agent (Bash)
   │  audio say "…"                      ~5ms binary
   ▼
 audio CLI ──── UNIX socket ────►  audiod (same binary, `audio daemon run`)
 (Swift, stateless)   NDJSON       Swift daemon owns:
   auto-spawns daemon               • socket server (many clients, control lane never blocks)
   if socket dead                   • FIFO job queue (1 active — one GPU, one speaker)
   (flock-guarded;                  • PLAYBACK: AVAudioSourceNode pull-render fed by a lock-free
    only say/render/warm/voices       ring buffer; adaptive 1–2-frame prebuffer; sample-accurate
    auto-boot — stop/status           50ms fade-stop; exact underrun counting; device stays open
    never wake a 7B model             across jobs; auto-recovers on device change/sleep-wake
    to say "nothing running")       • WAV tee: same PCM stream written incrementally to disk,
                                      sealed before `done` is reported (flat RAM on 55-min jobs)
                                    • worker supervision (lazy spawn, restart w/ backoff, kill esc.)
                                    • idle timer (ContinuousClock): 1h after last job →
                                      stop worker, exit, rm socket → ZERO idle processes
                                        │ stdio: NDJSON ctrl in / framed events+PCM out
                                        ▼
                                    worker (Python, vibevoice_mlx.worker) owns:
                                    • model (pre-quantized snapshot), voices, tokenizer
                                    • chunking, generation, per-token cancel checks
                                    • ONE corrected continuous PCM stream out (chunk gaps +
                                      causal-tail splice internal) for both say and render
                                    • voice encoding; exits on stdin EOF (orphan-proof)
```

**Warm-vs-frugal resolution**: warm = worker resident during the active hour (sub-second TTFS); frugal = after 1h idle everything exits (zero processes, zero RAM) and the next call pays a fast cold boot (target ≤10s, see below) that the CLI narrates. Between jobs while warm, worker calls `mx.clear_cache()` to trim MLX buffer-cache RSS.

**Why playback in the daemon, not Python**: this week's root-caused bug — MLX generation holds the GIL ~90ms/token, starving any in-process Python audio callback into an audible ~11Hz pulse. The current fix is a second Python process; a compiled daemon does it natively, keeps the device open across jobs (zero device-open latency), and makes `stop` instant (<100ms fade) even mid-55-minute-job. A dedicated Swift-architecture review (report to be saved at `audio-now/docs/swift-design.md`) settled the internals: pull-model `AVAudioSourceNode` render block touching only atomics (prebuffer/fade/underruns all live in the render gate — no locks shared with the real-time thread, priority inversion structurally impossible); one `Daemon` actor for all control state; dedicated threads for the worker's stdout/stderr pipes. **Backpressure is free**: the ring is bounded (~43s); when full, the reader stops reading, the kernel pipe fills, the worker's stdout write blocks, and generation throttles to realtime — no protocol machinery, flat memory on unbounded jobs.

### Protocols (boring on purpose)

**CLI ↔ daemon** — NDJSON over `~/.audio-now/run/daemon.sock`, one request line per connection, event lines back until a terminal event. Requests: `{cmd: say|render|stop|wait|status|voices|voice_add|warm|shutdown, text, voice, voices{"0":"carter",…}, seed, out, format, detach}`. Event stream: `queued → started → ttfa{ms} → progress{chunk i/n, generated_s, played_s, rtf} → done{wav, duration_s, underruns, warnings[]} | error{code, message, hint}`. For `say`, **`done` fires only after the ring has audibly drained** — `wait` means "speech finished," not "generation finished" (turn-taking correctness). `wait` on a finished job answers instantly from a small recent-results cache.

**daemon ↔ worker** — worker stdin: NDJSON control (`generate/cancel/encode_voice/list_voices/shutdown`; worker exits on stdin EOF, so a `kill -9`'d daemon can never leak a 6GB orphan); worker stdout: length-prefixed frames `[1B type][4B LE len][payload]`, type `J` = JSON event (`ready/started/pcm_begin/progress/done/cancelled/error/fatal`), `A` = raw float32 24kHz PCM (3200-sample/133ms frames); stderr → daemon log (drained by a dedicated thread — an undrained stderr pipe wedges the worker and mimics a model hang). Debuggable with `nc -U` / hexdump.

### On-disk layout (the only durable state)

```
~/.audio-now/
  config.json          # model/snapshot path, python path, idle_timeout_s (env-overridable)
  voices/              # NAME.safetensors + voices.json manifest (migrated: carter=default, femaleAnchor w/ known-hiss note)
  out/                 # say_/render_ wavs, ring-pruned to last 50
  run/daemon.sock, daemon.pid, spawn.lock
  log/daemon.log       # daemon + worker stderr, rotated
```

Code: SwiftPM package at `vibevoice/audio-now/` (targets: `AudioNowCore` library + `audio` executable + tests); Python side in the existing engine repo: `vibevoice-mlx/vibevoice_mlx/worker.py` + `export_snapshot.py`. Install: `make install` → binary at `~/.local/bin/audio` (on PATH, name is free).

---

## AX — the agent interface (theory of mind up front)

Six verbs. Everything else an agent might want is composition and gets shown, not shipped.

| verb | semantics | key flags |
|---|---|---|
| `audio say "text"` | speak on speakers; **blocks until playback ends** (turn-taking default) | `--voice --seed --async --interrupt --json` |
| `audio render f.txt --out f.wav` | text→wav, no playback, streams progress | `--voice N=V …` (multi-speaker map) `--seed --json` |
| `audio stop` | instantly stop playback + cancel active job (fades, no click) | `--all` (also clears queue) |
| `audio wait [job]` | block until a job finishes; how `--async` callers re-synchronize | `--timeout` |
| `audio status` | instant, never queued: `cold(nothing running) / warming(3.2s…) / ready / speaking(job 7, chunk 3/16, 41s in)` + queue + voices + `idle shutdown in 41m` + expected TTFS | `--json` |
| `audio voices` | list; `voices add NAME clip.wav` encodes + caches (warns if clip noise floor is high — clones inherit hiss) | |

(`audio warm` and `audio daemon stop|logs` exist but the skill teaches they're rarely needed.)

Decisions made *as* the primary user of agent tools:

1. **Agents fear hanging commands** (Bash default timeout ~2min). `say` estimates duration (words÷2.4); if >90s it refuses *fast* with the exact two correct alternatives in the error: `--async` (returns job id immediately) or `render`. No silent mode-switching.
2. **Agents can't hear.** Every job returns verifiable evidence: measured `audio_s` vs expectation, `ttfs_s`, `underruns`, `short_chunks` warnings (this week's regurgitation detector), and the wav path for replay/ASR-check. `status` shows what's audible *right now*.
3. **Errors teach.** Every failure names the fix: unknown voice → lists voices + the `voices add` line; daemon boot failure → last 5 log lines inline; text with digits (numbers spoken poorly) → warning suggesting the agent normalize ("write numbers as words") since *the agent is the best text normalizer in the system*.
4. **Cold boot is narrated, not suffered**: `say` on cold prints `warming model (~8s)…` to stderr immediately, then proceeds. Skill teaches the pre-warm pattern: fire `audio warm` at conversation start, hidden by the agent's first thinking turn.
5. **Concurrent sessions are normal** (several Claude instances share one Mac): flock-guarded spawn, FIFO queue with `queued behind job 7 (~40s)` feedback, `--interrupt` for barge-in, control lane always responsive.
6. **Paths just work**: relative paths resolved, output dirs auto-created — `speak`'s top two documented errors become non-errors.
7. **No emotion tags** (chatterbox feature; VibeVoice doesn't support them) — the skill says so explicitly and teaches punctuation/wording for prosody, so agents don't cargo-cult `[sigh]` from the old skill.
8. **Multi-speaker scripts** use the model's native `Speaker 0:`/`Speaker 1:` line format with `--voice 0=carter --voice 1=maya` mapping; long multi-speaker scripts chunk at *speaker-turn boundaries* (new — serve.py refuses to chunk them, which would early-stop long dialogues).

New skill: `~/.claude/skills/audio-now/` (SKILL.md ≤150 lines: the 6 verbs, 4 worked patterns — conversational turn, pre-warm, long article live, two-voice dialogue render — constraints, troubleshooting). Old `speak-tts`/`speakturbo*` skills are **left untouched** (they're symlinks into separate published git repos) — flagged to user for removal/archival later.

---

## Performance plan (measured targets, not vibes)

| metric | today | target | mechanism |
|---|---|---|---|
| warm TTFS (short say) | 0.69–0.90s | **≤0.55s median** | device already open (0 vs 20–80ms) · prebuffer 1 frame adaptive vs fixed 2 (−133ms) · short first chunk on long texts · no HTTP/curl hop |
| cold boot → ready | ~45–60s | **≤10s** | **pre-quantized snapshot** (today we load ~14GB fp16 and quantize *every boot*; verified in `load_weights.py` — snapshot = pure ~5.4GB mmap load incl. int8 diffusion head) · drop `transformers` for `tokenizers` tokenizer.json (−5–8s import+load; verified `tokenize_text` only needs `.encode`) · `HF_HUB_OFFLINE=1` · parallel component loads · measure warmup compile (Metal PSO cache may already persist across runs) |
| cold → first sound | ~60s | **≤12s** | boot + warm path |
| idle >1h | 5–6GB resident forever | **0 processes / 0 RAM** | idle timer → graceful worker+daemon exit |
| idle, warm window | ~6GB + buffer cache | model only | `mx.clear_cache()` after each job |
| stop latency | impossible (pkill) | **<150ms** | daemon fade + per-token cancel flag in `generate()` loop (clean insertion point verified at generate.py:492) |

Step 1 of implementation is a **boot/TTFS instrumentation harness** — every lever above gets a before/after number, and any lever that doesn't pay is dropped. P2 (only after targets measured): per-voice KV-prefix cache — prompt layout verified compatible (voice section strictly precedes text, e2e_pipeline.py:193–250), would cut ~150–250ms of prefill; skip if targets are met without it.

Quality is **not** renegotiated: same model, same chunking fixes (400-char sentence chunks, fresh prompt per chunk, per-chunk causal-tail splice, 120ms gaps), same 0.0000-floor bar, wav = batch decode. Regurgitation mitigations carry over (expected-duration check → `warnings`; seed re-roll documented).

---

## Implementation steps

1. **Snapshot + measurement** — `export_snapshot.py` (one-time: quantized model incl. int8 head + tokenizer.json → `~/.audio-now/model/`); extend loader to boot from it; instrument boot phases + TTFS. Gate: boot ≤10s or a written explanation of the floor.
2. **Worker** — `vibevoice_mlx/worker.py` (strictly typed, mypy-clean): framed stdio protocol, ports serve.py's chunking + tail-splice + duration checks, adds speaker-turn chunking, short-first-chunk, per-token cancel (robust to being blocked mid-write on a full pipe — stop sets the daemon-side discard flag first, which drains the pipe), exit-on-stdin-EOF, `encode_voice`, `mx.clear_cache()` between jobs. No wav writing, no playback, no HTTP — pure text→PCM+events. Testable headless: `worker_bench.py` drives it over pipes, asserts frame stream == serve.py output for fixed seed. `generate.py` gains optional `cancel_check` callback (only engine change).
3. **Swift core** (build order per design report: codecs → ring/wav → sockets → daemonize) — package skeleton (`audio` exe + `AudioNowCore` lib + `fakeworker` test exe; this plan + the full design report get persisted as `audio-now/PLAN.md` + `audio-now/docs/swift-design.md`); protocol codecs frozen first with round-trip tests (they're the contract the worker author codes against); lock-free `PCMRingBuffer` + incremental `WavWriter` (stress/header tests); POSIX socket server on a serial DispatchQueue; `posix_spawn`+`SETSID` daemonize with `spawn.lock` (CLI-side flock) + `daemon.pid` (daemon-lifetime flock proving socket staleness); pure job-queue FSM + idle timer with injected clock (unit-tested at ms scale).
4. **Playback** — `AVAudioSourceNode` render gate (idle/filling/playing/fading FSM in atomics): adaptive prebuffer starting at 1 frame (escalates on early underrun), sample-accurate 50ms fade-stop, exact underrun counts, engine warm across jobs, `AVAudioEngineConfigurationChange` restart (headphone unplug / sleep-wake). Proven standalone via a hidden `audio _tone` subcommand feeding synthetic 133ms frames at 1.3× cadence with injectable stalls (port of this week's starvation tests) — first audible milestone, no model needed. `fakeworker` (sine-PCM speaker of the worker protocol with crash/hang/ignore-cancel flags) then drives the full pipeline before the 7B model ever enters the picture.
5. **CLI verbs + lifecycle glue** — say/render/stop/wait/status/voices/warm/daemon; spawn-if-dead with flock; cold-boot narration; `--json` everywhere; exit codes. Idle-shutdown E2E with `AUDIO_NOW_IDLE_TIMEOUT_S=15`.
6. **Voices + install + skill** — migrate carter (default) + femaleAnchor (hiss-caveat) from `bench/voices/`; `make install` → `~/.local/bin/audio`; write the `audio-now` skill.
7. **Acceptance** — scripted: warm TTFS ×5 (target check), cold E2E, stop <150ms mid-long-say, two concurrent CLIs queue correctly, idle shutdown, worker-crash recovery, 10-min two-voice render (floor 0.0000, no early stop), `speak`-parity spot-checks. User ear-verification session. log.md STEP entries throughout (protocol); memory updated at the end.

## Verification

- Each step has its own gate above; final acceptance is step 7's scripted suite + the user listening: one conversational exchange (warm TTFS feel), one `audio stop` mid-sentence, one long article streamed live, one two-voice render.
- Regression guard: worker frame stream bit-compared to serve.py output at fixed seed before serve.py is retired.

## Risks / notes

- **Warmup (Metal kernel compile) may dominate cold boot** if PSO caching doesn't persist across processes → measured in step 1; fallback is accepting ~one extra second, not exotic caching.
- **Headless-daemon pitfalls are pre-identified with named mitigations** (from the Swift design review): App Nap → `ProcessInfo.beginActivity` held for daemon lifetime; SIGPIPE from disconnecting clients → `SIG_IGN` + `SO_NOSIGPIPE`; strict-concurrency at the real-time boundary → RT state confined to `Atomic`-only `@unchecked Sendable` holders, no locks/allocation in the render block; Foundation `Process` stderr-pipe deadlock → mandatory drain thread; engine self-stops on device change → config-change observer restarts it. Playback needs **no** TCC/mic permission (output only). Step 4's bench proves all of it before anything depends on it.
- **Failure matrix designed up front** (worker crash mid-job → fade + partial-but-valid wav + respawn w/ backoff; hung worker ignoring cancel → SIGKILL + respawn, warmth sacrificed for correctness; client Ctrl-C mid-say → job keeps playing, `audio stop` is the killswitch; daemon `kill -9` → flock proves staleness, stdin-EOF reaps the orphan worker; disk full → speech continues, wav marked failed). These become step 7's failure drills.
- Snapshot format must round-trip MLX mixed quantization (4-bit body + 8-bit head): loader already does structural-quantize-then-load for the pre-quantized path, so this is an extension, not new machinery.
- No `speed` knob in v1 (VibeVoice has no native rate control; faking it post-hoc would cost quality) — protocol carries an `extra{}` passthrough for future knobs.
- serve.py stays until acceptance passes, then is retired to avoid two warm-server pathways.

## Explicitly not building (composition beats features)

batch mode, concat, `--estimate`, resume manifests, emotion tags, HTTP API, Linux support. The skill shows the composition one-liners (loop for batch, `ffmpeg` for concat, words÷2.4 for estimates). Long renders already survive interruption better than speak's manifests did: the wav is written incrementally as chunks finish.
