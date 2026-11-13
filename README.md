# kokoro-beater

Native **Nim** TTS engine running the Kokoro v1.0 ONNX model — a drop-in
replacement for the `kokoro-onnx` Python package, with zero Python, no venv,
no numpy/torch, and byte-identical audio output.

```
bin/kokoro-beater "Hello, world!" --voice af_bella --out hello.wav
```

## Build, test, run

```bash
make build        # -> bin/kokoro-beater (nim c -d:release --mm:arc)
make models       # copy kokoro-v1.0.onnx + voices-v1.0.bin into ./models
                  #   MODELS_SRC=/path/to/models to override; ./models is gitignored
make test         # compile+run every assertion-bearing suite; nonzero exit on failure
make selfcheck    # synth a fixed sentence and verify the WAV end to end
make blind-check  # prove the selfcheck actually fails when blinded
```

**Build into `bin/`.** The vendored `libespeak-ng` and `libonnxruntime` are resolved relative to the
executable's own directory and its parent, so a binary built anywhere else dies asking for
`KOKORO_ESPEAK_LIB` / `KOKORO_ONNX_LIB`. `make build` handles this; a bare `nim c` to another path
does not.

`make test` covers `t_vocab`, `t_g2p`, `t_emotions`, `t_profile`, `t_voiceforge`. `t_espeak` is a
debug harness that prints rather than asserts, so it is excluded from the suite and run separately
with `make test-espeak`.

## Resident mode (`--serve`)

One process, many utterances. The model, espeak and the voice container load once, which removes
the per-invocation startup from every request after the first.

```bash
bin/kokoro-beater --serve
{"text":"Hello there.","voice":"bf_emma","out":"/tmp/a.wav"}   # -> one JSON response line
{"text":"Second one.","voice":"am_onyx","out":"/tmp/b.wav"}    # -> one JSON response line
```

Request keys: `text` and `out` (required), `voice`, `speed`, `emotion`, `trim`, `pauses`.
Response: `{"ok":true,"out":...,"samples":N,"seconds":s,"chunks":N,"tokens":N,"g2p_ms":...,
"synth_ms":...,"trim_ms":...,"write_ms":...,"wall_ms":...}` or `{"ok":false,"error":"..."}`.
stdout carries only responses; `SERVE READY startup_ms=<n> voices=<n>` and warnings go to stderr.

Measured 2026-11-13, 10 short sentences (~2.5 s of audio each), same binary:

| mode | total | per utterance |
|---|---|---|
| 10 separate processes | 14.73 s | ~1.47 s (493 ms of it is startup) |
| one `--serve` process | 7.74 s | 0.60–0.88 s |

Output is byte-identical between the two modes (10/10 files `cmp` clean), and identical again to a
whole-chapter render through the audiobook pipeline. Resident mode is what close-to-real-time use
needs; single-shot is the thing for one-off commands.

## Why it beats the Python path

| | kokoro-onnx (python) | kokoro-beater (nim) |
|---|---|---|
| Runtime deps | venv, numpy, onnxruntime, espeakng_loader | one ~300KB binary |
| Cold start | 3-5s (python + imports) | 0.41-0.50 s (ORT model load; benched 2026-11-13) |
| RTF, 1258 chars -> 102.0 s audio | ~0.18 (not re-measured) | 0.186-0.191 (benched 2026-11-13) |
| Long-form | in-memory concat | streaming to disk, no ceiling |
| Audio parity | — | correlation 1.000000 vs python, measured 2026-11-07; not re-verified since |

## Measured numbers, and how to reproduce them

Host: raven (Ryzen 12-core, R9700 not used — this engine is CPU-only). Binary built by `make build`.
One run is noise; each figure below is 3 runs.

```bash
# throughput: fixed bench text (1258 chars -> 102.02 s of audio)
bin/kokoro-beater --bench --threads 4      # rtf 0.1859  startup 411 ms  peak rss 966 MB
bin/kokoro-beater --bench --threads 8      # rtf 0.1869  startup 411 ms
bin/kokoro-beater --bench                  # rtf 0.1907-0.2010 (ORT default thread count)

# short-utterance cost is startup-dominated, not throughput-bound
bin/kokoro-beater "Good evening." --out /tmp/s.wav --json   # startup ~430 ms, synth ~280 ms
```

Thread count matters: 4 and 8 beat the ORT default here. Numbers move with the text used, so quote
the text and the flags with the number or the number means nothing.

## How it works

1. **espeak.nim** — dlopen's the vendored `libespeak-ng.so.1.52.0`, replicates
   phonemizer's exact espeak call contract
   (`espeak_Initialize(0x02,0,data,0)` → `SetVoiceByName("en-us")` →
   `TextToPhonemes(ptr, 1, 0x5F02)`, break on NUL **or empty** — the python
   wrapper loops only on NUL, which hangs on espeak ≥1.52).
2. **phonemize.nim** — faithful port of phonemizer's EspeakBackend pipeline:
   strip punctuation into chunks with B/E/I/A position marks → phonemize each
   chunk separately → restore marks (mark.index = source line number).
   Byte-identical output vs `tokenizer.phonemize()`.
3. **vocab.nim** — the 114-entry Kokoro vocab transcribed from config.json.
4. **npz.nim** — hand-rolled .npz parser (ZIP central-directory walk + zlib
   inflate via dlopen) that loads all 54 voices; no numpy needed.
5. **onnx.nim + vendor/kb_ort.c** — thin ctypes-free ORT shim: dlopen the
   vendored `libonnxruntime.so.1.28.0` (`KOKORO_ONNX_LIB` env override),
   run `tokens/style/speed → audio`.
   **Style rows are indexed by `tokens.len` — NOT voice-stride** (the voices
   table is a [54][510][1][256] with the model selecting row = token count).
   **Tokens are padded** `[0, ...tokens, 0]` — the model's reshape needs the
   full sequence.
6. **trim.nim** — librosa.effects.trim replica (frame RMS 2048/512, top_db=60).
7. **kbcli.nim** — CLI surface for TTS generation. 
   Long-form splits text at sentence boundaries, streams each phoneme batch straight to the WAV — no
   in-memory ceiling. The emotions are PCA-derived from the real voices' prosody data.

## CLI Flags Reference

| Flag | Description |
|---|---|
| `--voice <name\|expr>` | Voice name (e.g. `af_bella`) or blend expression (e.g. `0.5*af_bella+0.5*am_onyx`). |
| `--out <file>` | Path for the output `.wav` file (default: `out.wav`). |
| `--speed <float>` | Speech speed multiplier, clamped to `0.5..2.0` bounds (default: `1.0`). |
| `--threads <int>` | Number of ONNX threads to use. |
| `--model <path>` | Path to the ONNX model (`kokoro-v1.0.onnx`). |
| `--voices <path>` | Path to the voices bin file (`voices-v1.0.bin`). |
| `--list` | Lists all available voices in the `.bin` container and exits. |
| `--json` | Outputs JSON profiling metrics instead of standard text logs. |
| `--phonemes` | Prints the generated phonemes to stderr. |
| `--g2p <mode>` | G2P engine to use: `misaki` (default) or `espeak` (legacy bit-parity). |
| `--emotion <name>` | Name of the emotion to apply (e.g., `cheerful`, `angry`). |
| `--emotion-file <path>` | Path to the emotions JSON file (default: `src/emotions.json`). |
| `--style-offset <float>` | Multiplier for the emotion vector offset (default: `1.0`). |
| `--no-trim` | Disables trailing/leading silence trimming on audio chunks. |
| `--no-pause` | Disables inter-sentence silence pauses. |
| `--bench` | Runs performance benchmarks for metrics and prints a report. |
| `--espeak-lib <path>` | Override path to the `libespeak-ng` shared library. |
| `--espeak-data <path>` | Override path to the `espeak-ng-data` directory. |

## Feed contract (the hard part — all verified)

- `tokens` `[1, n]` int64 — **padded** with 0 at both ends (pad token id 0).
- `style` `[1, 256]` float32 — row selected by **unpadded** `len(tokens)`.
- `speed` `[1]` float32 — must be ≥ 0.5 (a `0.0` default makes the model's
  `duration = sigmoid(...) / speed` blow up the reshape → `{0,1,2,256}` error).
- Output 24 kHz float32 mono.

## Environment

`KOKORO_MODELS` (dir with `kokoro-v1.0.onnx` + `voices-v1.0.bin`),
`KOKORO_ONNX_LIB`, `KOKORO_ESPEAK_LIB`, `KOKORO_ESPEAK_DATA`, `KB_DEBUG=1`.

## Runtime deps (NOT in git, ~44MB)

To keep the repo light for remote agents, these heavy runtime files are
gitignored but expected on disk next to the binary (bin/../vendor/):

- `libonnxruntime.so.1.28.0` (24MB) — copy from
  `~/Downloads/audiobook/.venv/lib/python3.12/site-packages/onnxruntime/capi/`
- `libespeak-ng.so.1.52.0` + `espeak-ng-data/` (19MB) — copy from
  `~/Downloads/audiobook/.venv/lib/python3.12/site-packages/espeakng_loader/`

The C headers (`vendor/onnxruntime_*.h`) ARE in git — only the binaries are
excluded. `kb_ort.c` + the header live in git so the shim still compiles.

## Build

```
nim c -d:release --mm:arc -o:bin/kokoro-beater src/kbcli.nim
```

Vendor: `onnxruntime_c_api.h` + the libs from `~/.hermes/nim/kokoro-beater/vendor/`.