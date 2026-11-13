## kbcli.nim — kokoro-beater: native Nim Kokoro TTS engine.
##
## Usage: kokoro-beater [text] [options]
##   --voice NAME   voice (default af_bella; --list to enumerate)
##   --speed F      0.5..2.0 (default 1.0)
##   --out FILE     output wav (default out.wav)
##   --list         list voices and exit
##   --no-trim      keep chunk edge silence (python-lib parity)
##   --no-pause     no inter-chunk pauses inserted
##   --phonemes     echo the phoneme string before synthesizing
##   --threads N    onnxruntime intra-op threads (default: library default)
##   --model PATH   override model onnx
##   --voices PATH  override voices npz
##   --json         emit stats as a JSON object on stderr
##   --selfcheck    synthesize a fixed sentence, verify the WAV, exit 0/1
##
## Text comes from argv (joined) or from stdin when no positional text.
## Long-form is native: text is spoken in phoneme batches of <=510 tokens,
## streamed straight to the output file — no in-memory ceiling.

import std/[os, strutils, streams, times, math, json, algorithm, posix, tables]
import ./espeak, ./vocab, ./npz, ./onnx, ./trim, ./phonemize, ./misaki_g2p, ./voiceforge, ./emotion, ./emotions

proc peakRssKb*(): int =
  var usage: Rusage
  if getrusage(RUSAGE_SELF, addr usage) == 0:
    return int(usage.ru_maxrss)
  return 0

proc formatBenchReport*(textChars: int, audioSeconds: float64, startupMs: int, rtf: float64, peakRssKb: int, g2pMs, synthMs, trimMs, writeMs: int): string =
  result = "bench: text_chars=" & $textChars & " audio_seconds=" & formatFloat(audioSeconds, ffDecimal, 2) & " startup_ms=" & $startupMs & " rtf=" & formatFloat(rtf, ffDecimal, 4) & " peak_rss_kb=" & $peakRssKb & "\n" &
           "bench: g2p_ms=" & $g2pMs & " synth_ms=" & $synthMs & " trim_ms=" & $trimMs & " write_ms=" & $writeMs

proc buildProfileJson*(voice, model: string, textChars, phonemes, chunks, tokens: int, audioSeconds: float64, startupMs, synthMs: int, rtf: float64, sampleRate, peakRssKb, g2pMs, t_synthMs, trimMs, writeMs: int): JsonNode =
  result = %*{
    "voice": voice,
    "model": model,
    "text_chars": textChars,
    "phonemes": phonemes,
    "chunks": chunks,
    "tokens": tokens,
    "audio_seconds": round(audioSeconds, 4),
    "startup_ms": startupMs,
    "synth_ms": synthMs,
    "rtf": round(rtf, 4),
    "sample_rate": sampleRate,
    "peak_rss_kb": peakRssKb,
    "profile": {
      "g2p_ms": g2pMs,
      "synth_ms": t_synthMs,
      "trim_ms": trimMs,
      "write_ms": writeMs
    }
  }

const
  BenchText* = """
It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.
However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters.
"My dear Mr. Bennet," said his lady to him one day, "have you heard that Netherfield Park is let at last?"
Mr. Bennet replied that he had not.
"But it is," returned she; "for Mrs. Long has just been here, and she told me all about it."
Mr. Bennet made no answer.
"Do you not want to know who has taken it?" cried his wife impatiently.
"You want to tell me, and I have no objection to hearing it."
This was invitation enough.
"Why, my dear, you must know, Mrs. Long says that Netherfield is taken by a young man of large fortune from the north of England; that he came down on Monday in a chaise and four to see the place, and was so much delighted with it, that he agreed with Mr. Morris immediately; that he is to take possession before Michaelmas, and some of his servants are to be in the house by the end of next week."
"What is his name?"
"Bingley."
"Is he married or single?"
"""

  SampleRate = 24000
  DefaultOutFile = "out.wav"
  SelfcheckText = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
  SelfcheckMinSeconds = 1.0
  SelfcheckMaxSeconds = 20.0
  SelfcheckMinPeak = 3000
  VoiceFloats = 510 * 256      # per-voice style array, in floats
  TextChunkChars = 2048        # max text fed to espeak per call (memory + rate)

type
  Config = object
    text: string
    voice: string
    speed: float32
    outFile: string
    trim: bool
    pauses: bool
    showPhonemes: bool
    jsonOn: bool
    threads: int
    model: string
    voices: string
    espeakLib: string
    espeakData: string
    listOnly: bool
    g2p: string
    emotion: string
    emotionFile: string
    styleOffset: float
    bench: bool
    selfcheck: bool
    serve: bool

  WavWriter = object
    f: File
    dataBytes: int
    rate: int

proc defaultPaths(): tuple[model: string, voices: string] =
  let exeDir = getAppDir()
  let home = getHomeDir()
  var candidates: seq[string]
  if existsEnv("KOKORO_MODELS"):
    candidates.add getEnv("KOKORO_MODELS")
  candidates.add exeDir / "models"
  candidates.add exeDir.parentDir / "models"
  candidates.add getCurrentDir() / "models"
  candidates.add home / "Downloads" / "audiobook" / "models"
  for dir in candidates:
    for name in ["kokoro-v1.0.onnx", "kokoro-v1.0.fp16.onnx"]:
      let p = dir / name
      if fileExists(p):
        return (p, dir / "voices-v1.0.bin")
  raise newException(IOError,
    "kokoro model+voices not found (pass --model/--voices or set KOKORO_MODELS)")

proc resolveAsset*(name: string): string =
  ## Data files ship beside the sources (src/misaki_dict.txt, src/emotions.json)
  ## but the binary is normally run from bin/ or from a *different* working
  ## directory entirely. Resolve relative to the executable first, cwd last --
  ## a cwd-relative default is a portability bug, not a default.
  let exeDir = getAppDir()
  for d in [exeDir / "src", exeDir.parentDir / "src", exeDir, exeDir.parentDir]:
    let p = d / name
    if fileExists(p): return p
  for d in [getCurrentDir() / "src", getCurrentDir()]:
    let p = d / name
    if fileExists(p): return p
  return name

proc parseArgs(): Config =
  result = Config(voice: "af_bella", outFile: DefaultOutFile, speed: 1.0,
                  trim: true, pauses: true, g2p: "misaki", styleOffset: 1.0,
                  emotionFile: resolveAsset("emotions.json"))
  let argv = commandLineParams()
  var positionals: seq[string]
  var i = 0
  while i < argv.len:
    let a = argv[i]
    case a
    of "--voice", "--out", "--speed", "--threads", "--model", "--voices",
       "--espeak-lib", "--espeak-data", "--g2p", "--emotion", "--emotion-file", "--style-offset":
      if i + 1 >= argv.len:
        quit("missing value for " & a)
      case a
      of "--voice": result.voice = argv[i+1]
      of "--out": result.outFile = argv[i+1]
      of "--speed": result.speed = parseFloat(argv[i+1]).float32
      of "--threads": result.threads = parseInt(argv[i+1])
      of "--model": result.model = argv[i+1]
      of "--voices": result.voices = argv[i+1]
      of "--espeak-lib": result.espeakLib = argv[i+1]
      of "--espeak-data": result.espeakData = argv[i+1]
      of "--g2p": result.g2p = argv[i+1]
      of "--emotion": result.emotion = argv[i+1]
      of "--emotion-file": result.emotionFile = argv[i+1]
      of "--style-offset": result.styleOffset = parseFloat(argv[i+1])
      else: discard
      i += 2
    of "--no-trim": result.trim = false; i += 1
    of "--no-pause": result.pauses = false; i += 1
    of "--phonemes": result.showPhonemes = true; i += 1
    of "--json": result.jsonOn = true; i += 1
    of "--list": result.listOnly = true; i += 1
    of "--bench": result.bench = true; i += 1
    of "--selfcheck": result.selfcheck = true; i += 1
    of "--serve": result.serve = true; i += 1
    else:
      if a.len > 1 and a[0] == '-':
        quit("unknown option: " & a)
      positionals.add a
      i += 1
  result.text = positionals.join(" ")
  if result.selfcheck:
    result.text = SelfcheckText
    if result.outFile == DefaultOutFile:
      result.outFile = getTempDir() / "kokoro-selfcheck.wav"
  elif result.serve:
    # requests arrive as JSON lines on stdin; nothing to read here
    result.text = ""
  elif result.bench:
    result.text = BenchText
  elif result.text.len == 0:
    result.text = readAll(stdin)

proc pauseAfter(phonemes: string): int =
  ## inter-chunk pause in samples, keyed from the LAST chunk's ending
  ## punctuation (the audiobook-engine rule).
  let s = phonemes.strip()
  if s.len == 0: return int(0.25 * SampleRate)
  case s[^1]
  of '.', '!', '?': int(0.35 * SampleRate)
  of ',', ';', ':': int(0.15 * SampleRate)
  else: int(0.25 * SampleRate)

# --- streaming 16-bit PCM WAV writer ----------------------------------------

proc putU32LE(w: var WavWriter, value: uint32) =
  var b: array[4, byte]
  b[0] = byte(value and 0xFF)
  b[1] = byte((value shr 8) and 0xFF)
  b[2] = byte((value shr 16) and 0xFF)
  b[3] = byte((value shr 24) and 0xFF)
  discard w.f.writeBytes(b, 0, 4)

proc putU16LE(w: var WavWriter, value: uint16) =
  var b: array[2, byte]
  b[0] = byte(value and 0xFF)
  b[1] = byte((value shr 8) and 0xFF)
  discard w.f.writeBytes(b, 0, 2)

proc openWav(w: var WavWriter, path: string, rate: int) =
  w.f = open(path, fmWrite)
  w.rate = rate
  w.dataBytes = 0
  w.f.write("RIFF")
  w.putU32LE(0)                 # patched at finish
  w.f.write("WAVEfmt ")
  w.putU32LE(16)
  w.putU16LE(1)                 # PCM
  w.putU16LE(1)                 # mono
  w.putU32LE(uint32(rate))
  w.putU32LE(uint32(rate * 2))  # byte rate
  w.putU16LE(2)                 # block align
  w.putU16LE(16)                # bits
  w.f.write("data")
  w.putU32LE(0)                 # patched at finish

proc putSamples(w: var WavWriter, audio: openArray[float32]) =
  var buf: array[4096, uint8]
  var bi = 0
  for v in audio:
    var x = v
    if x > 1.0: x = 1.0
    elif x < -1.0: x = -1.0
    let s = int16(x * 32767.0)
    buf[bi] = uint8(s and 0xFF)
    buf[bi+1] = uint8((s shr 8) and 0xFF)
    bi += 2
    inc w.dataBytes, 2
    if bi == buf.len:
      discard w.f.writeBuffer(addr buf[0], buf.len)
      bi = 0
  if bi > 0:
    discard w.f.writeBuffer(addr buf[0], bi)

proc putSilence(w: var WavWriter, samples: int) =
  var zeros = newSeq[float32](min(samples, 65536))
  var done = 0
  while done < samples:
    let n = min(samples - done, zeros.len)
    w.putSamples(zeros.toOpenArray(0, n - 1))
    done += n

proc finishWav(w: var WavWriter) =
  w.f.setFilePos(4)
  w.putU32LE(uint32(36 + w.dataBytes))
  let sec = w.f.getFilePos
  w.f.setFilePos(sec)
  w.f.setFilePos(40)
  w.putU32LE(uint32(w.dataBytes))
  w.f.close()

# --- selfcheck -------------------------------------------------------------

proc le16(s: string, off: int): int =
  int(uint8(s[off])) or (int(uint8(s[off+1])) shl 8)

proc le32(s: string, off: int): int =
  int(uint8(s[off])) or (int(uint8(s[off+1])) shl 8) or
    (int(uint8(s[off+2])) shl 16) or (int(uint8(s[off+3])) shl 24)

proc verifyWav*(path: string): seq[tuple[name: string, ok: bool, detail: string]] =
  ## Reads a synthesized WAV back and asserts the properties a broken synth
  ## would violate. KOKORO_SELFCHECK_BLIND=1 inverts the peak requirement, so
  ## a passing run and a blind run differ -- the check is demonstrably able to
  ## fail rather than decorative.
  result.add ("file exists", fileExists(path), path)
  if not fileExists(path):
    return
  let raw = readFile(path)
  result.add ("length >= 44 (canonical header)", raw.len >= 44, $raw.len & " bytes")
  if raw.len < 44: return
  result.add ("RIFF/WAVE signature", raw[0..3] == "RIFF" and raw[8..11] == "WAVE",
              raw[0..3] & "/" & raw[8..11])
  result.add ("fmt chunk", raw[12..15] == "fmt ", raw[12..15])
  result.add ("PCM (format tag 1)", le16(raw, 20) == 1, $le16(raw, 20))
  result.add ("mono", le16(raw, 22) == 1, $le16(raw, 22))
  result.add ("sample rate 24000", le32(raw, 24) == SampleRate, $le32(raw, 24))
  result.add ("16 bits per sample", le16(raw, 34) == 16, $le16(raw, 34))
  result.add ("data chunk", raw[36..39] == "data", raw[36..39])
  let dataBytes = le32(raw, 40)
  result.add ("data size matches file", 44 + dataBytes == raw.len,
              $dataBytes & " vs " & $(raw.len - 44))
  let seconds = dataBytes.float / 2.0 / SampleRate.float
  result.add ("duration in [" & $SelfcheckMinSeconds & ", " & $SelfcheckMaxSeconds & "] s",
              seconds >= SelfcheckMinSeconds and seconds <= SelfcheckMaxSeconds,
              formatFloat(seconds, ffDecimal, 2) & " s")
  var peak = 0
  var i = 44
  while i + 1 < raw.len:
    var v = le16(raw, i)
    if v > 32767: v -= 65536
    let a = abs(v)
    if a > peak: peak = a
    i += 2
  let needPeak = if existsEnv("KOKORO_SELFCHECK_BLIND"): 40000 else: SelfcheckMinPeak
  result.add ("peak amplitude >= " & $needPeak & " (not silence)", peak >= needPeak, $peak)

proc reportSelfcheck(checks: seq[tuple[name: string, ok: bool, detail: string]]): int =
  var fails = 0
  for c in checks:
    stderr.writeLine((if c.ok: "PASS  " else: "FAIL  ") & c.name & " -- " & c.detail)
    if not c.ok: inc fails
  if fails == 0:
    stderr.writeLine("SELFCHECK PASS (" & $checks.len & " checks)")
  else:
    stderr.writeLine("SELFCHECK FAIL (" & $fails & "/" & $checks.len & " failed)")
  return if fails == 0: 0 else: 1

# --- main ------------------------------------------------------------------

# --- resident engine -------------------------------------------------------

type
  EngineState = object
    esp: LibEspeak
    vocab: Vocab
    voices: Npz
    vnames: seq[string]
    modelPath: string
    emTable: Table[string, seq[float32]]
    emLoaded: bool
    startupMs: int

  RenderStats = object
    textChars: int
    phonemeTotal: int
    tokenTotal: int
    chunkCount: int
    audioSamples: int
    g2pMs: int
    synthMs: int
    trimMs: int
    writeMs: int
    wallMs: int
    audioSeconds: float64

proc resolveModelPaths(cfg: Config): tuple[model: string, voices: string] =
  if cfg.model.len > 0:
    result.model = cfg.model
    result.voices = if cfg.voices.len > 0: cfg.voices else: cfg.model.parentDir / "voices-v1.0.bin"
  else:
    (result.model, result.voices) = defaultPaths()

proc listVoiceNames(cfg: Config): seq[string] =
  let (_, voicesPath) = resolveModelPaths(cfg)
  let npz = readNpz(voicesPath, VoiceFloats)
  for e in npz.entries: result.add e.name
  result.sort()

proc loadEngine(cfg: Config): EngineState =
  ## Everything expensive, loaded once. --serve reuses this for every request;
  ## single-shot mode pays it per process (that is the 0.45 s startup).
  let (modelPath, voicesPath) = resolveModelPaths(cfg)
  let t0 = epochTime()
  result.modelPath = modelPath
  result.voices = readNpz(voicesPath, VoiceFloats)
  for x in result.voices.entries: result.vnames.add x.name
  result.vnames.sort()

  let exeDir = getAppDir()
  let espeakLib = if cfg.espeakLib.len > 0: cfg.espeakLib else: defaultEspeakLibrary(exeDir)
  let espeakData = if cfg.espeakData.len > 0: cfg.espeakData else: defaultEspeakData(exeDir)
  result.esp = loadEspeak(espeakLib)
  result.esp.init(espeakData)

  onnxStart(modelPath, cfg.threads)
  result.vocab = newVocab()   # default-init has an EMPTY table -> zero tokens
  result.startupMs = int((epochTime() - t0) * 1000)

  if cfg.emotion.len > 0:
    try:
      result.emTable = loadEmotions(cfg.emotionFile)
      result.emLoaded = true
    except Exception as e:
      stderr.writeLine("warning: emotion file " & cfg.emotionFile &
                       " not found or valid, using builtin fallback (" & e.msg & ")")

proc renderToFile(e: var EngineState, cfg: Config, text, outFile: string): RenderStats =
  ## One text -> one WAV, start to finish. Single-shot mode, --selfcheck and
  ## --serve all go through here, so there is exactly one synthesis path.
  result.textChars = text.len
  result.wallMs = 0
  var wav: WavWriter
  openWav(wav, outFile, SampleRate)

  let wallStart = epochTime()

  # split text into espeak-sized pieces, keeping sentence boundaries
  var pieces: seq[string]
  let textLen = text.len
  var pos = 0
  while pos < textLen:
    var endP = min(pos + TextChunkChars, textLen)
    # don't split mid-word unless we hit the end
    if endP < textLen:
      var cut = -1
      for k in countdown(endP - 1, pos):
        if text[k] in {'.', '!', '?', '\n'}:
          cut = k + 1
          break
      if cut > 0:
        endP = cut
    pieces.add text[pos ..< endP]
    pos = endP

  for pi, piece in pieces:
    let g2p_start = epochTime()
    let phonemes = if cfg.g2p == "espeak": phonemize(e.esp, piece)
                   else: misakiG2p(e.esp, piece, dictPath = resolveAsset("misaki_dict.txt"))
    result.g2pMs += int((epochTime() - g2p_start) * 1000)
    if cfg.showPhonemes:
      stderr.writeLine("PHONEMES: " & phonemes.strip())
    result.phonemeTotal += phonemes.len
    let batches = splitPhonemes(phonemes)

    for bi, batch in batches:
      let toks = e.vocab.tokenize(batch)
      if toks.len == 0: continue
      let idx = min(toks.len, 509)
      let base = idx * 256

      let synth_start = epochTime()

      # forge voice array dynamically
      let forged = forgeVoice(cfg.voice, e.voices)
      var style = forged[base ..< base + 256]

      if cfg.emotion.len > 0:
        var appliedNew = false
        if e.emLoaded:
          try:
            applyEmotionVector(style, cfg.emotion, cfg.styleOffset, e.emTable)
            appliedNew = true
          except Exception as ex:
            stderr.writeLine("warning: emotion error: " & ex.msg)
        if not appliedNew:
          applyEmotion(style, cfg.emotion, cfg.styleOffset)

      # clamp speed
      var spd = cfg.speed.float32
      if spd < 0.5f32: spd = 0.5f32
      if spd > 2.0f32: spd = 2.0f32

      var chunk = synthChunk(toks, style, spd)
      result.synthMs += int((epochTime() - synth_start) * 1000)
      if cfg.trim:
        let trim_start = epochTime()
        chunk = trimSilence(chunk)
        result.trimMs += int((epochTime() - trim_start) * 1000)
      let write_start = epochTime()
      wav.putSamples(chunk)
      result.writeMs += int((epochTime() - write_start) * 1000)
      inc result.chunkCount
      result.tokenTotal += toks.len
      let isLastOverall = pi == pieces.len - 1 and bi == batches.len - 1
      if cfg.pauses and not isLastOverall:
        let pause_start = epochTime()
        wav.putSilence(pauseAfter(batch))
        result.writeMs += int((epochTime() - pause_start) * 1000)
      if result.chunkCount mod 20 == 0 and not cfg.jsonOn:
        stderr.writeLine("[" & $result.chunkCount & " chunks...]")

  let finish_start = epochTime()
  finishWav(wav)
  result.writeMs += int((epochTime() - finish_start) * 1000)

  result.wallMs = int((epochTime() - wallStart) * 1000)
  result.audioSamples = wav.dataBytes div 2
  result.audioSeconds = float64(result.audioSamples) / float(SampleRate)

proc rtfOf(s: RenderStats): float64 =
  s.wallMs.float / 1000.0 / max(s.audioSeconds, 0.001)

# --- resident mode (--serve) -----------------------------------------------
#
# One JSON object per line on stdin, one JSON object per line on stdout.
#   {"text": "...", "out": "/path/x.wav", "voice": "bf_emma",
#    "speed": 1.0, "emotion": "", "trim": true, "pauses": false}
# -> {"ok": true, "out": ..., "samples": N, "seconds": s, "synth_ms": N, ...}
# The model, espeak and the voice container are loaded ONCE for the whole
# session, which removes the per-chunk process-startup cost entirely.
# Timing/log lines go to stderr so stdout stays machine-readable.

proc serveLoop(base: Config) =
  var e = loadEngine(base)
  var cfg = base
  stderr.writeLine("SERVE READY startup_ms=" & $e.startupMs & " voices=" & $e.vnames.len)
  stderr.flushFile()
  for line in stdin.lines:
    let s = line.strip()
    if s.len == 0: continue
    var req: JsonNode
    try:
      req = parseJson(s)
    except CatchableError as ex:
      stdout.writeLine($(%*{"ok": false, "error": "bad json: " & ex.msg}))
      stdout.flushFile()
      continue
    if not req.hasKey("text") or not req.hasKey("out"):
      stdout.writeLine($(%*{"ok": false, "error": "text and out are required"}))
      stdout.flushFile()
      continue
    cfg.voice = if req.hasKey("voice"): req["voice"].getStr() else: base.voice
    cfg.speed = if req.hasKey("speed"): req["speed"].getFloat().float32 else: base.speed
    cfg.emotion = if req.hasKey("emotion"): req["emotion"].getStr() else: base.emotion
    cfg.trim = if req.hasKey("trim"): req["trim"].getBool() else: base.trim
    cfg.pauses = if req.hasKey("pauses"): req["pauses"].getBool() else: base.pauses
    try:
      let st = renderToFile(e, cfg, req["text"].getStr(), req["out"].getStr())
      stdout.writeLine($(%*{"ok": true,
                            "out": req["out"].getStr(),
                            "samples": st.audioSamples,
                            "seconds": st.audioSeconds,
                            "chunks": st.chunkCount,
                            "tokens": st.tokenTotal,
                            "g2p_ms": st.g2pMs,
                            "synth_ms": st.synthMs,
                            "trim_ms": st.trimMs,
                            "write_ms": st.writeMs,
                            "wall_ms": st.wallMs}))
    except CatchableError as ex:
      stdout.writeLine($(%*{"ok": false, "error": ex.msg}))
    stdout.flushFile()

# --- entry point -----------------------------------------------------------

proc main() =
  let cfg = parseArgs()

  if cfg.listOnly:
    for n in listVoiceNames(cfg): echo n
    return

  if cfg.serve:
    serveLoop(cfg)
    return

  var e = loadEngine(cfg)
  let st = renderToFile(e, cfg, cfg.text, cfg.outFile)

  if cfg.bench:
    stderr.writeLine(formatBenchReport(st.textChars, st.audioSeconds, e.startupMs, rtfOf(st),
                                       peakRssKb(), st.g2pMs, st.synthMs, st.trimMs, st.writeMs))
  elif cfg.jsonOn:
    let j = buildProfileJson(cfg.voice, e.modelPath, st.textChars, st.phonemeTotal,
                             st.chunkCount, st.tokenTotal, st.audioSeconds, e.startupMs,
                             st.wallMs, rtfOf(st), SampleRate, peakRssKb(), st.g2pMs,
                             st.synthMs, st.trimMs, st.writeMs)
    stderr.writeLine(j.pretty())

  stderr.writeLine("wrote " & cfg.outFile & " (" & $st.audioSamples & " samples, " &
                   formatFloat(st.audioSeconds, ffDecimal, 2) & " s)")

  if cfg.selfcheck:
    let code = reportSelfcheck(verifyWav(cfg.outFile))
    removeFile(cfg.outFile)
    quit(code)

when isMainModule:
  main()