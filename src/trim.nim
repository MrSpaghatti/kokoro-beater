## trim.nim — librosa.effects.trim replica (the exact algorithm kokoro-onnx
## uses): frame RMS (2048/512, centered padding), threshold = 60 dB below the
## max frame RMS, slice [first*512, (last+1)*512).

import std/math

proc frameRms(y: seq[float32], frameLen = 2048, hop = 512): seq[float32] =
  let pad = frameLen div 2
  let n = y.len + 2 * pad
  if n < frameLen: return @[]
  result = newSeq[float32]((n - frameLen) div hop + 1)
  for f in 0 ..< result.len:
    var acc = 0.0
    let off = f * hop - pad   # offset into the original signal (padded region = 0)
    for i in 0 ..< frameLen:
      let idx = off + i
      let v =
        if idx < 0 or idx >= y.len: 0.0
        else: float(y[idx])
      acc += v * v
    result[f] = float32(sqrt(acc / float(frameLen)))

proc trimSilence*(y: seq[float32], topDb: float = 60.0): seq[float32] =
  ## Librosa-style leading/trailing silence trim. Empty for all-silent input.
  if y.len == 0 or y.len < 2048:
    return y
  let r = frameRms(y)
  var mx = 0.0f32
  for v in r: mx = if v > mx: v else: mx
  if mx <= 0.0:
    return @[]
  let thr = float64(mx) * pow(10.0, -topDb / 20.0)
  var first, last = -1
  for i, v in r:
    if float64(v) > thr:
      if first < 0: first = i
      last = i
  if first < 0:
    return @[]
  let start = first * 512
  let endIdx = min(y.len, (last + 1) * 512)
  if start >= endIdx:
    return @[]
  return y[start ..< endIdx]