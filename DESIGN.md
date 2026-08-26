# Kokoro-Beater: Beat Kokoro On All Fronts (Pure Nim)

Target: take the working pure-Nim Kokoro TTS engine (this repo) and make it
**beat stock Kokoro** (https://github.com/hexgrad/kokoro, the `kokoro-v1.0`
82M StyleTTS2-style model) across the axes below — with **zero Python** at
runtime. The model graph is fixed (`models/kokoro-v1.0.onnx`, ONNX Runtime
dlopen'd via `vendor/kb_ort.c`). All wins below come from the **front-end
(G2P), voice/style engineering, and runtime** — NOT from a bigger neural net.

## Must keep working (regression baseline)

- `nim c -d:release --mm:arc -o:bin/kokoro-beater src/kbcli.nim` compiles.
- `bin/kokoro-beater "Hello" --out /tmp/keep.wav --json` produces a 24 kHz
  mono WAV, `--json` prints `{voice,text_chars,phonemes,chunks,tokens,
  audio_seconds,startup_ms,synth_ms,rtf,sample_rate}` to stderr.
- `--list` prints all 54 voice names from `voices-v1.0.bin`.
- Audio must remain **bit-identical** to `kokoro-onnx` when G2P is in
  "legacy espeak" mode (`--g2p espeak`).

## Axes to beat (in priority order)

### 1. Front-end quality — misaki-grade G2P in pure Nim

Stock Kokoro routes G2P through raw espeak-ng, which misreads many words
(`boogeyman` → "boogerman", `hang` wrong vowel, etc.). The audiobook pipeline
already proved the fix: **misaki** (hexgrad/misaki) is a token-level dict +
rules layer on top of espeak. Port its core to Nim:

- `src/misaki_g2p.nim`: port the English `G2P` logic — the word/exception
  dictionary, the `EspeakFallback.E2M` phoneme remap (from misaki's
  `en/espeak.py`), the tokenizer rules (word segmentation, abbreviation
  expansion, number/cardinal/ordinal handling, punctuation retain).
- The espeak backend stays (already vendored) as the *fallback phonemizer*
  under the rules — misaki still calls espeak for unknown words.
- New CLI flag `--g2p misaki` (default), `--g2p espeak` for legacy parity.
- Success: the misaki phoneme string for `"boogeyman any more"` matches
  `tests/fixtures/misaki_phonemes.txt` byte-for-byte, and `--g2p misaki`
  **speaks the word correctly** (verifiable by transcribing the wav).
- Reference signature (misaki 0.9.4, verified): `en.G2P(version='0.2.0')` —
  NO `lit`/`trf` kwargs in this version (the old `lit=True` calls are stale).
  Unknown words emit the `❓` glyph (`unk='❓'`); the model's vocab filter
  drops it, matching kokoro-onnx behavior.

### 2. Unlimited voices — style-space interpolation/extrapolation

Kokoro packs per-voice style as `[510, 1, 256]` (namespace rows = padded token
count). Stock exposes 54 fixed voices. Nim can synthesize **any** voice:

- `src/voiceforge.nim`: given 2+ voice style vectors from `voices-v1.0.bin`,
  produce new styles by (a) coordinate-wise interpolation `lerp(a,b,t)`,
  (b) extrapolation beyond the range, (c) PCA-ish blend of N voices
  (weighted sum).
- Style row is still selected by `tokens.len` (the [510,1,256] contract);
  the *forged* row must be the same 256-float layout. Reuse the existing
  npz reader.
- CLI: `--voice "0.5*af_bella+0.5*am_onyx"` — parse the expression, forge
  the row, speak. Keep a `--list` output for synthetic voices too
  (e.g. `--list --synthetic` shows blends of the 54).
- Success: transcribe `--voice 0.5*af_bella+0.5*am_onyx` "hello" and it
  sounds like a **blend** (not either parent), with valid audio (RMS
  within a factor of 2 of either parent).

### 3. Emotion / prosody control — the 128/128 style split

The Kokoro config has `style_dim: 128`; `model.py` splits the 256-dim style
as `ref_s[:, :128]` (timbre) + `ref_s[:, 128:]` (prosody/style). Stock never
exposes the second half. In Nim:

- Expose `--style-offset F` (add a scaled vector to the prosody half).
- Support data-driven emotions via `--emotion-file <path>` (defaults to `src/emotions.json`). 
  The file is a JSON mapping emotion names (e.g. `angry`, `whisper`, `cheerful`, `sad`, `calm`) 
  to an array of exactly 128 float offsets for the prosody half.
- If the file is missing or invalid, it emits a warning and falls back to a builtin 
  hardcoded directional offset (`applyEmotion`).
- `--emotion <name>` selects the offset vector which is then multiplied by `style-offset`.
- Must not change the timbre half (voice stays recognizable).
- Success: `--emotion cheerful` vs baseline on the same sentence differs
  measurably in pitch/energy (not bit-identical) and transcribes the same
  words.

### 4. Runtime wins (already partly done; finish)

- Keep the flat-memory streaming writer; add `--threads N` (already wired to
  ORT) so a full book streams without RAM growth.
- Add a `--speed F` sanity clamp (0.5..2.0, python parity).
- Add `--g2p` (above) and a `--profile` flag that prints per-stage ms
  (g2p/synth/trim/write) in the `--json` output.
- Goal: `startup_ms` under ~350ms, RTF ≤ 0.16 on 12 cores, long-form
  (≥1h audio) with memory flat.

## Verification (what YOU must run — source + compile only)

The runtime needs heavy vendor binaries (`libonnxruntime*.so`, `libespeak-ng*`,
`espeak-ng-data/`) that are NOT in the repo (gitignored, ~44MB). They exist
only on the author's machine. **In this sandbox you CANNOT run the binary
end-to-end.** Your verification is:

```bash
# 1. COMPILE — must succeed:
nim c -d:release --mm:arc -o:bin/kokoro-beater src/kbcli.nim
#    (write a minimal stub in tests/ if vendor files are needed at compile time
#     — but src/*.nim must typecheck clean; if a module needs the model at
#     runtime only, that's fine.)

# 2. FIXTURE-CONTRACT — your new modules must be structured so the audio
#    verification (run by the AUTHOR on HIS machine) uses these fixtures:
#    - --g2p espeak --phonemes 'boogeyman any more' output ==
#      tests/fixtures/espeak_phonemes.txt line 'misread'
#    - --g2p misaki --phonemes 'boogeyman any more' output ==
#      tests/fixtures/misaki_phonemes.txt line 'misread'
#    - audio corr vs reference.wav == 1.0 (legacy mode)
#    Make the phoneme strings a PURE function (no model dependency) so a
#    tiny unit test can assert them WITHOUT the runtime. Add
#    tests/t_g2p.nim that imports your module and checks the two fixture
#    strings directly (pure Nim, no vendor needed). Compile+run that.
```

Fixture files (checked in):
- `tests/fixtures/espeak_phonemes.txt` — kokoro-onnx `tokenizer.phonemize` targets.
- `tests/fixtures/misaki_phonemes.txt` — misaki 0.9.4 `en.G2P(version='0.2.0')`
  targets (unk='❓'), for `hello/misread/quote` strings.
- `tests/fixtures/reference.wav` — bit-exact audio target (author runs the corr).

**Do NOT attempt to run the full binary** if vendor/ is missing; that's expected.
Your job is: correct, compiling Nim source + the pure-function G2P unit test.

## Deliverables

- `src/misaki_g2p.nim`, `src/voiceforge.nim`, `src/emotion.nim` (or similar
  layout) + kbcli wiring.
- README section documenting `--g2p / --voice <expr> / --emotion`.
- All committed + pushed to `main` (or a clearly-named branch).
- Report the verification numbers (parity corr, RTF, startup_ms, and the
  transcribed blend/emotion lines).

Do NOT touch `vendor/libonnxruntime*`, `vendor/kb_ort.c` (the runtime shim),
`vendor/libespeak-ng*`, or `espeak-ng-data` unless a bug requires it — those
are frozen. Keep the engine single-binary: no subprocess to python, ever.