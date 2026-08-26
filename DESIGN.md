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
  misaki's python output byte-for-byte, and `--g2p misaki` **speaks the word
  correctly** (verifiable by transcribing the wav).

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

- Expose `--style-offset F` (add a scaled vector to the prosody half) and
  `--emotion <name>` mapping to a learned/perpendicular offset in the
  128-dim prosody subspace (e.g. `angry`, `whisper`, `cheerful`, `sad`,
  `calm`) — port a small hand-set of offsets by fitting to the existing
  voices' prosody halves (PCA direction per emotion is acceptable).
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

## Verification (run these yourself before reporting done)

```bash
cd /home/spag/Downloads/audiobook    # has .venv with kokoro-onnx + misaki
# 1. misaki parity — python side:
NIM_EXE=/home/spag/hermes/nim/kokoro-beater/bin/kokoro-beater
"$NIM_EXE" --g2p espeak  --phonemes "boogeyman any more"   # legacy
# must equal:  python -c 'from kokoro_onnx import Kokoro; k=Kokoro(...); print(k.tokenizer.phonemize("boogeyman any more"))'
"$NIM_EXE" --g2p misaki  --phonemes "boogeyman any more"   # misaki-grade
# must equal:  python misaki en.G2P output for those words
# 2. audio regression:
"$NIM_EXE" --g2p espeak "Hello, world! This is a test for kokoro." --out /tmp/reg.wav
# compare vs python ref (existing script ~/.hermes/scripts/kb_cmp.sh) — corr must be 1.000000
# 3. voice blend:
"$NIM_EXE" --voice '0.5*af_bella+0.5*am_onyx' "Hi there" --out /tmp/blend.wav --json
# 4. emotion:
"$NIM_EXE" --emotion cheerful "I can hardly believe it" --out /tmp/emo.wav --json
# vs baseline, must differ but transcribe the same
```

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