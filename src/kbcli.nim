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

import std/[os, strutils, streams, times, math, json, algorithm, posix]
import ./espeak, ./vocab, ./npz, ./onnx, ./trim, ./phonemize, ./misaki_g2p, ./voiceforge, ./emotion

const
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
    styleOffset: float

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
                  trim: true, pauses: true, g2p: "misaki", styleOffset: 1.0)
  let argv = commandLineParams()
  var positionals: seq[string]
  var i = 0
  while i < argv.len:
    let a = argv[i]
    case a
    of "--voice", "--out", "--speed", "--threads", "--model", "--voices",
       "--espeak-lib", "--espeak-data", "--g2p", "--emotion", "--style-offset":
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
      of "--style-offset": result.styleOffset = parseFloat(argv[i+1])
      else: discard
      i += 2
    of "--no-trim": result.trim = false; i += 1
    of "--no-pause": result.pauses = false; i += 1
    of "--phonemes": result.showPhonemes = true; i += 1
    of "--json": result.jsonOn = true; i += 1
    of "--list": result.listOnly = true; i += 1
    else:
      if a.len > 1 and a[0] == '-':
        quit("unknown option: " & a)
      positionals.add a
      i += 1
  result.text = positionals.join(" ")
  if result.text.len == 0:
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
  defer: finishWav(wav)

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
        applyEmotion(style, cfg.emotion, cfg.styleOffset)
      
      # clamp speed
      var spd = cfg.speed.float32
      if spd < 0.5f32: spd = 0.5f32
      if spd > 2.0f32: spd = 2.0f32
      
      var chunk = synthChunk(toks, style, spd)
      t_synth_ms += int((epochTime() - synth_start) * 1000)
      if cfg.trim:
        chunk = trimSilence(chunk)
      wav.putSamples(chunk)
      inc chunkCount
      tokenTotal += toks.len
      let isLastOverall = pi == pieces.len - 1 and bi == batches.len - 1
      if cfg.pauses and not isLastOverall:
        wav.putSilence(pauseAfter(batch))
      if chunkCount mod 20 == 0 and not cfg.jsonOn:
        stderr.writeLine("[" & $chunkCount & " chunks...]")

  let synthMs = int((epochTime() - t1) * 1000)
  let audioSamples = wav.dataBytes div 2
  let audioLen = float64(audioSamples) / float(SampleRate)

  if cfg.jsonOn:
    let j = %*{
      "voice": cfg.voice,
      "model": modelPath,
      "text_chars": cfg.text.len,
      "phonemes": phonemeTotal,
      "chunks": chunkCount,
      "tokens": tokenTotal,
      "audio_seconds": round(audioLen, 4),
      "startup_ms": startupMs,
      "synth_ms": synthMs,
      "rtf": round(synthMs.float / 1000.0 / max(audioLen, 0.001), 4),
      "sample_rate": SampleRate,
      "profile": {
        "g2p_ms": t_g2p_ms,
        "synth_ms": t_synth_ms
      }
    }
    stderr.writeLine(j.pretty())

  stderr.writeLine("wrote " & cfg.outFile & " (" & $audioSamples & " samples, " &
                   formatFloat(audioLen, ffDecimal, 2) & " s)")

when isMainModule:
  main()