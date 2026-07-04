---
name: audio-now
description: Speak to your user out loud, or produce narrated audio files — local VibeVoice 7B TTS with voice cloning via the `audio` CLI. Warm daemon, ~0.4s to first sound, self-managing (auto-starts, exits after 1h idle). Supersedes the speak/speakturbo skills. Use for voice replies, reading articles aloud, audiobooks, multi-voice dialogue.
---

# audio-now

One command: `audio`. The 7B daemon starts itself on first use (~3s to first
sound cold, ~0.4s warm; a cold start delays the first word, never clips it).

## The verbs

| verb | what it does |
|---|---|
| `audio say "text"` | speak on the speakers; **blocks until playback finishes there** — a mechanical wait, turn-taking safe. No `--voice` = the default voice (marked in `audio voices`) |
| `audio say notes.md` | a `.md`/`.pdf` path is auto-detected and parsed for the ear; a `.txt` is spoken verbatim — never transformed, never refused |
| `audio render file.txt --out out.wav` | file (or `-` = stdin, never literal text) → wav, no playback; `--out` optional (defaults into `~/.audio-now/out/`) |
| `audio stop` | silence + cancel + clear queue in <150ms |
| `audio wait [job]` | block until that job (no arg: everything) finishes; `--timeout SECS` exits 3 if not done |
| `audio status` | instant, read-only, poll freely: cold/warming/ready, playing what, queue, idle countdown |
| `audio warm` | load the model now (~3s, returns when ready). Warmth lasts 1h from the last command; re-warm after a long lull |
| `audio voices` | list voices; `audio voices add NAME clip.wav` clones a new one |

Every verb takes `--json` (NDJSON); the terminal event looks like
`{"event":"done","job":"j-000042","duration_s":5.8,"ms":420,"wav":"…/j-000042_say.wav","warnings":[]}`
— these fields exist only with `--json`; without it you get the human line
shown below. Warnings print in both modes (`⚠` on stderr). Exit codes: 0 success, 2 error
(stderr names the fix); 3 exists only for `wait --timeout` — `say`/`render`
exit 0 or 2, never hang. `--seed`/`--preview` work on both `say` and `render`;
render jobs appear in `status`/`wait`/`stop` like any job.

## Patterns

**Conversational turn** — the blocking return is your turn-taking gate:
```bash
audio say "Found it — the bug was in the retry loop. Want the details?"
# -> spoke 5.8s · first sound 0.42s · wav ~/.audio-now/out/j-000042_say.wav
```
Exit 0 from a *blocking* say proves playback finished on the speakers — treat
that as "delivered" for turn-taking; no stronger "heard" signal exists. For a
one-off say, never bother warming first (cold only delays the first word).
Unattended pass rule: no `⚠` lines and duration ≈ word count ÷ 2.4 (works for
any input, files included; `duration_s` counts speech only, not model load). If a take *sounded* wrong: the seed is
fixed by default (42) — a bare re-run reproduces the identical take, so
re-roll with a new one: `audio say "…" --seed 7` (re-rolls the whole job;
there is no per-chunk retry — on long reads re-seed only if unusable).

**A session of spoken updates**: `audio warm` once, then one plain blocking
`say` per update. There is no persistent mode; a new `say` queues FIFO behind
whatever is playing.

**Read something long aloud, live.** `say` refuses estimates >90s (words÷2.4)
so it never hangs your tool call — `--async` (or `render`) lifts that cap:
```bash
audio say article.txt --async   # -> "j-000012 queued — audio wait j-000012 to block, audio stop to cancel"
audio status                    # chunk 4/16, 45s generated, 41s played
audio stop                      # the user says "enough"
audio say "Short version: it was the retry loop."   # answer interruptions ALOUD — it's a voice conversation
```
Sound starts in ~0.4s (warm) and plays while later chunks generate. For
`--async`, exit 0 = *queued*; completion evidence (`duration_s`, warnings)
arrives on the `done` event via `audio wait <job>` — `status` only shows live
progress until the job clears. No resume exists after stop/`--interrupt`/
crash: resume ≈ seconds-played × 2.4 words into the source, backed up to the
previous sentence boundary — write the remainder to a new file and say that.

**Read a document aloud** — md/pdf are parsed for the ear (structure → prose,
PDF page furniture swept). A dense md/pdf (tables/formulas/code) is **refused
with findings** (category + line numbers). Don't predict the complexity
score — `--preview` always succeeds and shows you:
```bash
audio say report.md --preview   # exact spoken text + findings, even for a doc the real run would refuse
audio say report.md             # long docs: --async or render
```
A refusal means the automatic parse would sound like noise to a listener
(a linearized table is not speech) — it is not the >90s length gate. Respond
in order: 1) rewrite the flagged sections as listener-prose in a copy
(tables → sentences, formulas → words), 2) retry — mind the >90s cap for the
retry too. Never reach for `--force` on your own judgement — it is only for
when the user explicitly asked for the lossy gist, and it still won't lift
the >90s gate. In `--json`: findings = `ingest`
event (md/pdf only), refusal adds `error` code `complex_formatting`.

**Audiobook / narration to a file** (~1.4s of audio per second of wall):
```bash
audio render chapter.txt --voice carter --out chapter.wav
# streams: chunk 3/12 — 245s … then: rendered 1667.2s -> chapter.wav
```
`render` blocks until done — no `render --async` (async is say-only), no
batch verb: loop in your own shell, backgrounding if long.

**Two-voice dialogue** — script lines must use the literal tokens
`Speaker 1: …` / `Speaker 2: …` (numbered from 1, no gaps — NOT names like
`Ana:`; names bind to voices only via the flag). Labels route voices and are
stripped, never spoken. Fold narration/stage directions into dialogue or drop:
```bash
audio render dialog.txt --voice 1=carter --voice 2=femaleAnchor --out scene.wav
```

**Clone a voice.** Only the **first 10 seconds** are used — put clean speech
there. You can't listen: ask the user which stretch is cleanest, then cut it
to the front (no ffmpeg on this box — slice with python's `wave`). wav/flac/
mp3 load directly; m4a converts first: `afconvert -f WAVE -d LEI16 in.m4a out.wav`.
Noisy clips warn but still encode (clones inherit the room noise):
```bash
audio voices add maya ~/clips/maya_24k.wav
audio say "Quick check of the new voice." --voice maya
```

## Constraints that matter (read once)

- **Write digits as words in text YOU compose — the engine never converts
  them** ("$4.2M" → "four point two million dollars", "31%" → "thirty-one
  percent"; keep the unit). Existing files: accept the digit-heavy warning
  for a read-it-now; rewrite a copy only when fidelity matters.
- **No emotion tags** — `[sigh]`/`[laugh]` are read aloud as words. Use
  punctuation, wording, and rhythm for prosody.
- **Verify important audio by evidence**: `done` seconds ≈ words÷2.4, or
  transcribe the wav. A `short chunk` warning = the ~1-in-20 bad take → new
  `--seed`.
- **File input is literal-safe**: an argument is read as a file only if it
  exists (path-looking but missing → error, never spoken aloud).
- **Long jobs are safe**: chunked internally, wav written incrementally,
  `stop` works mid-job. One daemon, one FIFO queue across sessions.
  `say --interrupt` stops current playback AND clears the queue, then
  speaks — reserve it for genuinely time-sensitive barge-ins.

## Troubleshooting

- `audio status`, then `audio daemon logs`. Force-restart: `audio daemon stop`
  (self-starts on the next command). Boot failure → `pythonPath`/`modelDir`
  in `~/.audio-now/config.json`. Worker crash mid-job → partial wav kept,
  `[worker_crashed]`, next job respawns (~3s).
