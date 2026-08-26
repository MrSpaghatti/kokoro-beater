## onnx.nim — Nim side of the kb_ort C shim. Compiles the shim + header in,
## resolves the runtime lib at init via dlopen (see kb_ort.c).

import std/[os, strformat]

const vendorDir = currentSourcePath().parentDir.parentDir / "vendor"
{.compile: vendorDir & "/kb_ort.c".}
{.passC: "-I" & vendorDir.}
{.passL: "-ldl".}

proc kbOrtInit*(modelPath: cstring, threads: cint): cint
  {.cdecl, importc: "kb_ort_init".}
proc kbOrtSynth*(tokens: ptr int64, ntok: cint, style: ptr float32,
                 speed: float32, outP: ptr ptr float32, outLen: ptr int64): cint
  {.cdecl, importc: "kb_ort_synth".}
proc kbOrtError(): cstring {.cdecl, importc: "kb_ort_error".}
proc kbOrtFree(p: pointer) {.cdecl, importc: "kb_ort_free".}

proc onnxStart*(modelPath: string, threads: int = 0) =
  let rc = kbOrtInit(modelPath.cstring, threads.cint)
  if rc != 0:
    raise newException(IOError, "onnx init failed: " & $kbOrtError())

proc synthChunk*(tokens: seq[int64], style: seq[float32], speed: float32): seq[float32] =
  ## Run one phoneme batch through the model -> audio samples.
  ## Matches python exactly: tokens fed padded with pad-token 0 at both ends;
  ## style row selected by the UNPADDED token count in the caller.
  var rawTok = tokens
  var padded = newSeq[int64](tokens.len + 2)
  padded[0] = 0
  for i in 0 ..< tokens.len: padded[i + 1] = tokens[i]
  padded[padded.len - 1] = 0
  var rawStyle = style
  var outP: ptr float32 = nil
  var outLen: int64 = 0
  let rc = kbOrtSynth(addr padded[0], padded.len.cint, addr rawStyle[0],
                      speed, addr outP, addr outLen)
  if rc != 0:
    raise newException(IOError, "synth failed: " & $kbOrtError())
  result = newSeq[float32](outLen)
  if outLen > 0:
    copyMem(addr result[0], outP, outLen * 4)
  kbOrtFree(outP)