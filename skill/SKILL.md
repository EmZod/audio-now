---
name: audio-now
description: Speak to your user out loud, or produce narrated audio files — local VibeVoice 7B TTS with voice cloning via the `audio` CLI. Warm daemon, ~0.4s to first sound, self-managing (auto-starts, exits after 1h idle). Supersedes the speak/speakturbo skills. Use for voice replies, reading articles aloud, audiobooks, multi-voice dialogue.
---

# audio-now — give your user your voice

One command: `audio`. The 7B model daemon starts itself on first use (~3s), stays
warm for an hour of inactivity, then exits completely. You never manage it.

## The six verbs

| verb | what it does |
|---|---|
| `audio say "text"` | speak on the speakers; **blocks until the user has heard it** (turn-taking) |
| `audio say notes.md` | a `.txt`/`.md`/`.pdf` path is auto-detected, parsed for the ear, and spoken |
| `audio render file.txt --out out.wav` | text/md/pdf → wav file, no playback; streams `chunk i/n` progress |
| `audio stop` | instantly silence playback (50ms fade) + cancel and clear the queue |
| `audio wait [job]` | block until a job (or everything) finishes — pairs with `--async` |
| `audio status` | instant: cold/warming/ready, what's playing, queue, idle countdown |
| `audio voices` | list voices; `audio voices add NAME clip.wav` clones a new one |

Every verb takes `--json` for NDJSON events. Exit 0 = success, 2 = error (stderr
explains and names the fix), 3 = `wait --timeout` expired.

## Patterns

**Conversational turn** (speak, then continue when the user has heard it):
```bash
audio say "Found it — the bug was in the retry loop. Want the details?"
```
Result line reports measured seconds spoken, time-to-first-sound, and the wav path.

**Start of a voice session** — pre-warm while you think:
```bash
audio warm   # ~3s cold, instant if already warm; next say starts in ~0.4s
```

**Read something long aloud, live** (`say` refuses >90s estimates — by design,
so you never hang a tool call):
```bash
audio say --async "$(cat article_speakable.txt)"   # returns job id immediately
audio status        # chunk 4/16, 45s generated, 41s played
audio stop          # the user says "enough"
```

**Read a document aloud** (`say`/`render` take `.txt`/`.md`/`.pdf` paths —
markdown/PDF are parsed: headers and lists become prose, simple tables are
linearized, code blocks and display math become spoken markers, running PDF
headers/page numbers are swept):
```bash
audio say report.md --preview   # print exactly what would be spoken + findings
audio say report.md             # speaks it (long docs: --async / render)
```
If the file is dense with tables/formulas/code it is **refused with a findings
report** (categories, line numbers, complexity score ≥ 10). That's your cue:
rewrite those sections for the ear in a copy — prose instead of tables,
words instead of formulas — then retry. You are the best rewriter in the
system; the listener should never hear TTS artifacts. `--force` speaks the
best-effort transform anyway; `.txt` files are never refused (their content
is your contract). Findings land on stderr (human) or as an `ingest` event
(`--json`).

**Audiobook / narration to a file:**
```bash
audio render chapter.txt --voice carter --out chapter.wav
```

**Two-voice dialogue** (script lines `Speaker 1: …` / `Speaker 2: …`, numbered
from 1, contiguous):
```bash
audio render dialog.txt --voice 1=carter --voice 2=femaleAnchor --out scene.wav
```

**Clone a voice** from 10–30s of clean speech (it will warn if the clip is
noisy — clones inherit the reference's room noise):
```bash
audio voices add maya ~/clips/maya_24k.wav
```

## Constraints that matter (read once)

- **Normalize text yourself first** — you are the best text normalizer in this
  system. Write numbers, dates, citations as words ("two fourteen B", "March
  second"), expand acronyms you want spelled out. The CLI warns on digit-heavy
  input but won't rewrite it. File ingestion handles *structure* (tables,
  headers, links), not numbers — digit-heavy files still warn.
- **File input is literal-safe**: an argument is only read as a file if it
  actually exists (or unambiguously looks like a path, which errors when
  missing — a typo'd path is never spoken aloud).
- **No emotion tags.** `[sigh]`/`[laugh]` are not supported by this model
  (that was the old speak skill's engine) — they'll be read aloud. Use
  punctuation, wording, and sentence rhythm for prosody.
- **Wrong-sounding output?** (~1-in-20 generations can mumble or speak the
  voice reference's own words — you'll usually see a `short chunk` warning):
  re-run with a different `--seed`. Verify important audio by duration
  (`done` reports seconds; expect ~words÷2.4) or transcribe the wav.
- **Long jobs are safe**: audio is chunked internally (no drift, no hiss),
  the wav is written incrementally, and `audio stop` works mid-job in <150ms.
- Concurrent sessions share one daemon and one pair of speakers: jobs queue
  FIFO; `say --interrupt` barges in; `status` never blocks.

## Troubleshooting

- `audio status` first. Then `audio daemon logs`.
- Boot failure usually means `pythonPath`/`modelDir` in `~/.audio-now/config.json`
  (written by `make install` in `vibevoice/audio-now/`).
- Worker crash mid-job returns `[worker_crashed]` and keeps the partial wav;
  the next job respawns the model (~3s).
- Rebuild/install: `cd vibevoice/audio-now && make install`.
