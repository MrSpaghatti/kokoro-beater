## espeak.nim — libespeak-ng FFI, replicating the kokoro-onnx phonemizer path
## exactly: espeak_Initialize(0x02, 0, data, 0) -> SetVoiceByName -> 
## TextToPhonemes(ptr, 1, 0x5F02). The library is dlopen'd, so the binary
## stays self-contained next to vendor/.

import std/[dynlib, os, strutils]

type
  LibEspeak* = ref object
    lib*: LibHandle
    espeakInitialize*: proc(outMode, buflen: cint, path: cstring, option: cint): cint {.cdecl.}
    espeakSetVoiceByName*: proc(name: cstring): cint {.cdecl.}
    espeakTextToPhonemes*: proc(text: ptr ptr cchar, textMode, phonemeMode: cint): cstring {.cdecl.}
    espeakTerminate*: proc(): cint {.cdecl.}
    voiceSet*: bool

proc loadEspeak*(libPath: string): LibEspeak =
  result = LibEspeak()
  result.lib = loadLib(libPath)
  if result.lib == nil:
    raise newException(IOError, "cannot load libespeak-ng from " & libPath)
  result.espeakInitialize = cast[typeof(result.espeakInitialize)](result.lib.symAddr("espeak_Initialize"))
  result.espeakSetVoiceByName = cast[typeof(result.espeakSetVoiceByName)](result.lib.symAddr("espeak_SetVoiceByName"))
  result.espeakTextToPhonemes = cast[typeof(result.espeakTextToPhonemes)](result.lib.symAddr("espeak_TextToPhonemes"))
  result.espeakTerminate = cast[typeof(result.espeakTerminate)](result.lib.symAddr("espeak_Terminate"))
  if result.espeakInitialize.isNil or result.espeakSetVoiceByName.isNil or
     result.espeakTextToPhonemes.isNil or result.espeakTerminate.isNil:
    raise newException(IOError, "libespeak-ng missing required symbol")

proc init*(e: var LibEspeak, dataDir: string) =
  ## espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, dataDir, 0)
  let rc = e.espeakInitialize(0x02'i32, 0'i32, dataDir.cstring, 0'i32)
  if rc <= 0:
    raise newException(IOError, "espeak_Initialize failed (" & $rc & ") with data dir " & dataDir)

proc setVoice*(e: var LibEspeak, lang: string = "en-us") =
  if e.espeakSetVoiceByName(lang.cstring) != 0:
    raise newException(IOError, "espeak_SetVoiceByName failed for " & lang)
  e.voiceSet = true

proc rawPhonemes*(e: var LibEspeak, text: string): string =
  ## espeak_TextToPhonemes loop, exactly like the phonemizer wrapper: the
  ## library advances the char* in place; loop while it stays non-nil.
  if not e.voiceSet: e.setVoice()
  var pstr = text
  var pptr = cstring(pstr)         # library advances this pointer, data stays read-only
  var phandle = cast[ptr ptr cchar](addr pptr)
  result = ""
  while true:
    let chunk = e.espeakTextToPhonemes(phandle, 1'i32, 0x5F02'i32)  # ord('_')<<8 | 0x02
    if chunk == nil: break
    let s = $chunk
    if s.len == 0: break           # pointer consumed -> past the NUL; no more text
    result.add(s)

proc collapseSpaces(s: string): string =
  result = newStringOfCap(s.len)
  var prevSpace = false
  for c in s:
    if c == ' ':
      if not prevSpace: result.add(' ')
      prevSpace = true
    else:
      prevSpace = false
      result.add(c)

proc postprocess*(line0: string): string =
  ## Replicate phonemizer EspeakBackend._postprocess_line with kokoro's
  ## defaults: separator phone='', word=' ', with_stress=True, tie=None.
  var line = line0.strip()
  line = line.replace("\n", " ")
  line = collapseSpaces(line)
  line = line.replace("__", "_")   # re.sub(r"_+", "_")
  line = line.replace("_ ", " ")    # re.sub(r"_ ", " ")
  var words: seq[string]
  for w in line.split(' '):
    words.add w.strip().replace("_", "")
  result = collapseSpaces(words.join(" "))

proc close*(e: LibEspeak) =
  ## no-op except when we want to be tidy; dlopen'd handles die with process

proc defaultEspeakLibrary*(exeDir: string): string =
  ## Find the vendored libespeak-ng next to the executable (or one level up:
  ## bin/ -> project root).
  var roots = [exeDir, exeDir.parentDir]
  for r in roots:
    for p in [r / "vendor" / "libespeak-ng.so.1.52.0",
              r / "vendor" / "libespeak-ng.so.1",
              r / "libespeak-ng.so.1"]:
      if fileExists(p): return p
  if existsEnv("KOKORO_ESPEAK_LIB") and fileExists(getEnv("KOKORO_ESPEAK_LIB")):
    return getEnv("KOKORO_ESPEAK_LIB")
  raise newException(IOError, "libespeak-ng not found (set KOKORO_ESPEAK_LIB)")

proc defaultEspeakData*(exeDir: string): string =
  for r in [exeDir, exeDir.parentDir]:
    for p in [r / "vendor" / "espeak-ng-data", r / "espeak-ng-data"]:
      if dirExists(p): return p
  if existsEnv("KOKORO_ESPEAK_DATA") and dirExists(getEnv("KOKORO_ESPEAK_DATA")):
    return getEnv("KOKORO_ESPEAK_DATA")
  raise newException(IOError, "espeak-ng-data not found (set KOKORO_ESPEAK_DATA)")