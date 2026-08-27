# kokoro-beater

Native **Nim** TTS engine running the Kokoro v1.0 ONNX model — a drop-in
replacement for the `kokoro-onnx` Python package, with zero Python, no venv,
no numpy/torch, and byte-identical audio output.

```
bin/kokoro-beater "Hello, world!" --voice af_bella --out hello.wav
```

## Why it beats the Python path

| | kokoro-onnx (python) | kokoro-beater (nim) |
|---|---|---|
| Runtime deps | venv, numpy, onnxruntime, espeakng_loader | one ~300KB binary |
| Cold start | 3-5s (python + imports) | ~400ms (ORT model load) |
| RTF (R9700 12-core) | ~0.18 | ~0.159 |
| Long-form | in-memory concat | streaming to disk, no ceiling |
| Audio parity | — | correlation 1.000000 vs python |

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
7. **kbcli.nim** — CLI: text argv→join or stdin; `--voice/--speed/--out/
   --list/--phonemes/--json/--no-trim/--no-pause/--emotion/--style-offset/--emotion-file`. 
   Long-form splits text at sentence boundaries, streams each phoneme batch straight to the WAV — no
   in-memory ceiling. The emotions are PCA-derived from the real voices' prosody data.

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