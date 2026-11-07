## tests/t_voiceforge.nim — pure-Nim unit test for voice expression parsing and blending.
##
## Tests coordinate-wise interpolation (lerp), extrapolation, and 3+ voice blends,
## along with error paths for unknown/malformed expressions.
## 
## Note: This tests the pure logic in voiceforge.nim. The actual ONNX
## model output using these voices is tested separately.

import std/[strutils, math]
import voiceforge, npz

var failures = 0

proc check(label: string, got, want: bool) =
  if got == want:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    inc failures

# Create a mock Npz object with dummy voices for testing
var mockNpz = Npz()
var v1Seq = newSeq[float32](256)
var v2Seq = newSeq[float32](256)
var v3Seq = newSeq[float32](256)

for i in 0..<256:
  v1Seq[i] = 1.0f32
  v2Seq[i] = 2.0f32
  v3Seq[i] = 3.0f32

mockNpz.entries.add(NpzEntry(name: "v1", data: v1Seq))
mockNpz.entries.add(NpzEntry(name: "v2", data: v2Seq))
mockNpz.entries.add(NpzEntry(name: "v3", data: v3Seq))

# 1. Test Single Voice (should return original arrays directly)
let resSingle = forgeVoice("v1", mockNpz)
check("single voice returns exact array", resSingle == v1Seq, true)

# 2. Test Interpolation (lerp)
let resLerpMid = forgeVoice("0.5*v1+0.5*v2", mockNpz)
var lerpMidOk = true
for i in 0..<256:
  if abs(resLerpMid[i] - 1.5f32) > 1e-5: lerpMidOk = false
check("lerp at t=0.5", lerpMidOk, true)

let resLerp0 = forgeVoice("1.0*v1+0.0*v2", mockNpz)
var lerp0Ok = true
for i in 0..<256:
  if abs(resLerp0[i] - 1.0f32) > 1e-5: lerp0Ok = false
check("lerp at t=0", lerp0Ok, true)

let resLerp1 = forgeVoice("0.0*v1+1.0*v2", mockNpz)
var lerp1Ok = true
for i in 0..<256:
  if abs(resLerp1[i] - 2.0f32) > 1e-5: lerp1Ok = false
check("lerp at t=1", lerp1Ok, true)

let resLerp28 = forgeVoice("0.2*v1+0.8*v2", mockNpz)
var lerp28Ok = true
for i in 0..<256:
  # 0.2*1.0 + 0.8*2.0 = 0.2 + 1.6 = 1.8
  if abs(resLerp28[i] - 1.8f32) > 1e-5: lerp28Ok = false
check("lerp at t=0.8", lerp28Ok, true)

# 3. Test Extrapolation
let resExtrap = forgeVoice("-0.5*v1+1.5*v2", mockNpz)
var extrapOk = true
for i in 0..<256:
  # -0.5*1.0 + 1.5*2.0 = -0.5 + 3.0 = 2.5
  if abs(resExtrap[i] - 2.5f32) > 1e-5: extrapOk = false
check("extrapolation outside 0..1", extrapOk, true)

# 4. Test 3+ Voice Blend
let resBlend = forgeVoice("0.2*v1+0.3*v2+0.5*v3", mockNpz)
var blendOk = true
for i in 0..<256:
  # 0.2*1.0 + 0.3*2.0 + 0.5*3.0 = 0.2 + 0.6 + 1.5 = 2.3
  if abs(resBlend[i] - 2.3f32) > 1e-5: blendOk = false
check("3+ voice blend", blendOk, true)

# 5. Test Normalization
let resNorm = forgeVoice("2.0*v1+2.0*v2", mockNpz)
var normOk = true
for i in 0..<256:
  # Normalized weights should be 0.5, 0.5. Result 1.5
  if abs(resNorm[i] - 1.5f32) > 1e-5: normOk = false
check("auto-normalization of weights", normOk, true)

# 6. Test Errors - Unknown voice name
var raisedUnknown = false
try:
  discard forgeVoice("v99", mockNpz)
except ValueError:
  raisedUnknown = true
check("raises on unknown voice (single)", raisedUnknown, true)

var raisedUnknownBlend = false
try:
  discard forgeVoice("0.5*v1+0.5*v99", mockNpz)
except ValueError:
  raisedUnknownBlend = true
check("raises on unknown voice (blend)", raisedUnknownBlend, true)

# 7. Test Errors - Malformed Expression
var raisedMalformed = false
try:
  discard forgeVoice("0.5*v1+foo*v2", mockNpz)
except ValueError:
  raisedMalformed = true
check("raises on malformed expression", raisedMalformed, true)

# 8. Test Errors - Zero Total Weight
var raisedZeroWeight = false
try:
  discard forgeVoice("0.0*v1+0.0*v2", mockNpz)
except ValueError:
  raisedZeroWeight = true
check("raises on zero total weight", raisedZeroWeight, true)

# 9. Test Errors - Wrong vector length
var mockNpzBadLen = Npz()
var badSeq1 = newSeq[float32](100)
var badSeq2 = newSeq[float32](100)
mockNpzBadLen.entries.add(NpzEntry(name: "b1", data: badSeq1))
mockNpzBadLen.entries.add(NpzEntry(name: "b2", data: badSeq2))

# Currently forgeVoice does not enforce 256 vector length on the Npz side directly, 
# but if we wanted to test mismatched array length, we would raise. Let's see if 
# mismatched array lengths fail.
var mockNpzMismatch = Npz()
mockNpzMismatch.entries.add(NpzEntry(name: "v1", data: v1Seq))
mockNpzMismatch.entries.add(NpzEntry(name: "b1", data: badSeq1))
var raisedMismatch = false
try:
  discard forgeVoice("0.5*v1+0.5*b1", mockNpzMismatch)
except IndexDefect:
  raisedMismatch = true
check("raises on mismatched vector length (IndexDefect)", raisedMismatch, true)


if failures == 0:
  echo "\nALL TESTS PASSED"
  quit(0)
else:
  echo "\n", failures, " TEST(S) FAILED"
  quit(1)
