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
  candidates.add getCurrentDir() / "models"
  candidates.add home / "Downloads" / "audiobook" / "models"
  for dir in candidates:
    for name in ["kokoro-v1.0.onnx", "kokoro-v1.0.fp16.onnx"]:
      let p = dir / name
      if fileExists(p):
        return (p, dir / "voices-v1.0.bin")
  raise newException(IOError,
    "kokoro model+voices not found (pass --model/--voices or set KOKORO_MODELS)")

proc parseArgs(): Config =
  result = Config(voice: "af_bella", outFile: "out.wav", speed: 1.0,
                  trim: true, pauses: true, g2p: "misaki", styleOffset: 1.0, emotionFile: "src/emotions.json")
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
    else:
      if a.len > 1 and a[0] == '-':
        quit("unknown option: " & a)
      positionals.add a
      i += 1
  result.text = positionals.join(" ")
  if result.bench:
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

# --- main ------------------------------------------------------------------

proc main() =
  let cfg = parseArgs()

  var modelPath, voicesPath: string
  if cfg.model.len > 0:
    modelPath = cfg.model
    voicesPath = if cfg.voices.len > 0: cfg.voices else: cfg.model.parentDir / "voices-v1.0.bin"
  else:
    (modelPath, voicesPath) = defaultPaths()

  let t0 = epochTime()

  var voicesNpz = readNpz(voicesPath, VoiceFloats)
  var vnames: seq[string]
  for e in voicesNpz.entries: vnames.add e.name
  vnames.sort()
  if cfg.listOnly:
    for n in vnames: echo n
    return

  # With blends, exact voice name check may fail. 
  # We just pass it down to forgeVoice later, but we can keep list logic intact.

  # espeak
  let exeDir = getAppDir()
  let espeakLib = if cfg.espeakLib.len > 0: cfg.espeakLib else: defaultEspeakLibrary(exeDir)
  let espeakData = if cfg.espeakData.len > 0: cfg.espeakData else: defaultEspeakData(exeDir)
  var esp = loadEspeak(espeakLib)
  esp.init(espeakData)

  # onnx
  onnxStart(modelPath, cfg.threads)
  let startupMs = int((epochTime() - t0) * 1000)

  let vocab = newVocab()
  var wav: WavWriter
  openWav(wav, cfg.outFile, SampleRate)

  var phonemeTotal = 0
  var tokenTotal = 0
  var chunkCount = 0
  var textDone = 0

  # split text into espeak-sized pieces, keeping sentence boundaries
  var t1 = epochTime()
  var pieces: seq[string]
  let textLen = cfg.text.len
  var pos = 0
  while pos < textLen:
    var endP = min(pos + TextChunkChars, textLen)
    # don't split mid-word unless we hit the end
    if endP < textLen:
      var cut = -1
      for k in countdown(endP - 1, pos):
        if cfg.text[k] in {'.', '!', '?', '\n'}:
          cut = k + 1
          break
      if cut > 0:
        endP = cut
    pieces.add cfg.text[pos ..< endP]
    pos = endP
  let nPieces = pieces.len

  var t_g2p_ms = 0
  var t_synth_ms = 0
  var t_trim_ms = 0
  var t_write_ms = 0

  var globalEmTableLoaded = false
  var globalEmTable: Table[string, seq[float32]]
  if cfg.emotion.len > 0:
    try:
      globalEmTable = loadEmotions(cfg.emotionFile)
      globalEmTableLoaded = true
    except Exception as e:
      stderr.writeLine("warning: emotion file " & cfg.emotionFile & " not found or valid, using builtin fallback (" & e.msg & ")")

  for pi, piece in pieces:
    let g2p_start = epochTime()
    let phonemes = if cfg.g2p == "espeak": phonemize(esp, piece) else: misakiG2p(esp, piece)
    t_g2p_ms += int((epochTime() - g2p_start) * 1000)
    if cfg.showPhonemes:
      stderr.writeLine("PHONEMES: " & phonemes.strip())
    phonemeTotal += phonemes.len
    let batches = splitPhonemes(phonemes)

    for bi, batch in batches:
      let toks = vocab.tokenize(batch)
      if toks.len == 0: continue
      let idx = min(toks.len, 509)
      let base = idx * 256
      
      let synth_start = epochTime()
      
      # forge voice array dynamically
      let forged = forgeVoice(cfg.voice, voicesNpz)
      var style = forged[base ..< base + 256]
      
      if cfg.emotion.len > 0:
        var appliedNew = false
        if globalEmTableLoaded:
          try:
            applyEmotionVector(style, cfg.emotion, cfg.styleOffset, globalEmTable)
            appliedNew = true
          except Exception as e:
            # this shouldn't happen unless emotion name is unknown, fallback
            stderr.writeLine("warning: emotion error: " & e.msg)
        
        if not appliedNew:
          applyEmotion(style, cfg.emotion, cfg.styleOffset)
      
      # clamp speed
      var spd = cfg.speed.float32
      if spd < 0.5f32: spd = 0.5f32
      if spd > 2.0f32: spd = 2.0f32
      
      var chunk = synthChunk(toks, style, spd)
      t_synth_ms += int((epochTime() - synth_start) * 1000)
      if cfg.trim:
        let trim_start = epochTime()
        chunk = trimSilence(chunk)
        t_trim_ms += int((epochTime() - trim_start) * 1000)
      let write_start = epochTime()
      wav.putSamples(chunk)
      t_write_ms += int((epochTime() - write_start) * 1000)
      inc chunkCount
      tokenTotal += toks.len
      let isLastOverall = pi == pieces.len - 1 and bi == batches.len - 1
      if cfg.pauses and not isLastOverall:
        let pause_start = epochTime()
        wav.putSilence(pauseAfter(batch))
        t_write_ms += int((epochTime() - pause_start) * 1000)
      if chunkCount mod 20 == 0 and not cfg.jsonOn:
        stderr.writeLine("[" & $chunkCount & " chunks...]")

  let finish_start = epochTime()
  finishWav(wav)
  t_write_ms += int((epochTime() - finish_start) * 1000)

  let synthMs = int((epochTime() - t1) * 1000)
  let audioSamples = wav.dataBytes div 2
  let audioLen = float64(audioSamples) / float(SampleRate)

  let rtfVal = synthMs.float / 1000.0 / max(audioLen, 0.001)

  if cfg.bench:
    stderr.writeLine(formatBenchReport(cfg.text.len, audioLen, startupMs, rtfVal, peakRssKb(), t_g2p_ms, t_synth_ms, t_trim_ms, t_write_ms))
  elif cfg.jsonOn:
    let j = buildProfileJson(cfg.voice, modelPath, cfg.text.len, phonemeTotal, chunkCount, tokenTotal, audioLen, startupMs, synthMs, rtfVal, SampleRate, peakRssKb(), t_g2p_ms, t_synth_ms, t_trim_ms, t_write_ms)
    stderr.writeLine(j.pretty())

  stderr.writeLine("wrote " & cfg.outFile & " (" & $audioSamples & " samples, " &
                   formatFloat(audioLen, ffDecimal, 2) & " s)")

when isMainModule:
  main()