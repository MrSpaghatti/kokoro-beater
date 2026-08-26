import std/[os, strutils, tables, math]
import emotions

var failures = 0

proc check(label: string, got, want: bool) =
  if got == want:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    inc failures

let fixDir = currentSourcePath().parentDir / "fixtures"
let goodFix = fixDir / "emotions.json"
let badLenFix = fixDir / "emotions_bad_len.json"
let missingFix = fixDir / "missing_emotions.json"

# a. loadEmotions succeeds on tests/fixtures/emotions.json
var table: Table[string, seq[float32]]
var didRaise = false
try:
  table = loadEmotions(goodFix)
except Exception:
  didRaise = true
check("loadEmotions succeeds on valid JSON", not didRaise, true)
check("table has correct names", table.hasKey("test_fixture_a") and table.hasKey("test_fixture_b"), true)
if table.hasKey("test_fixture_a"):
  check("seq len 128", table["test_fixture_a"].len == 128, true)

# b. loadEmotions on a nonexistent path raises
didRaise = false
try:
  discard loadEmotions(missingFix)
except IOError:
  didRaise = true
except Exception:
  discard
check("loadEmotions raises on missing file", didRaise, true)

# c. loadEmotions on bad_len raises with "128"
didRaise = false
var errMsg = ""
try:
  discard loadEmotions(badLenFix)
except ValueError as e:
  didRaise = true
  errMsg = e.msg
except Exception:
  discard
check("loadEmotions raises on bad len", didRaise, true)
check("bad len msg contains 128", "128" in errMsg, true)

# d. applyEmotionVector with unknown emotion raises
didRaise = false
errMsg = ""
var dummyStyle = newSeq[float32](256)
try:
  applyEmotionVector(dummyStyle, "unknown_emotion", 1.0, table)
except ValueError as e:
  didRaise = true
  errMsg = e.msg
except Exception:
  discard
check("applyEmotionVector raises on unknown emotion", didRaise, true)
check("unknown msg contains known name", "test_fixture_a" in errMsg, true)

# e. applyEmotionVector modifies 128..255 and leaves 0..127 untouched
var styleOrig = newSeq[float32](256)
for i in 0..255:
  styleOrig[i] = float32(i)

var styleTest = styleOrig
applyEmotionVector(styleTest, "test_fixture_a", 1.0, table)

var prefixOk = true
for i in 0..127:
  if styleTest[i] != styleOrig[i]: prefixOk = false
check("prefix 0..127 untouched", prefixOk, true)

var suffixOk = true
var formulaOk = true
for i in 128..255:
  if i > 128 and styleTest[i] == styleOrig[i]: suffixOk = false
  let expectedDiff = float32(0.01 * float(i - 128))
  if abs(styleTest[i] - styleOrig[i] - expectedDiff) > 1e-4: formulaOk = false
check("suffix 128..255 modified", suffixOk, true)
check("suffix modified by formula", formulaOk, true)

# f. offset scaling works
var styleTest2 = styleOrig
applyEmotionVector(styleTest2, "test_fixture_a", 2.0, table)
var scaleOk = true
for i in 128..255:
  let delta1 = styleTest[i] - styleOrig[i]
  let delta2 = styleTest2[i] - styleOrig[i]
  if abs(delta2 - 2.0 * delta1) > 1e-4: scaleOk = false
check("offset scaling works", scaleOk, true)

# g. no-op cases
var styleTestNoOp = styleOrig
applyEmotionVector(styleTestNoOp, "", 1.0, table)
check("empty emotion leaves untouched", styleTestNoOp == styleOrig, true)

applyEmotionVector(styleTestNoOp, "test_fixture_a", 0.0, table)
check("0.0 offset leaves untouched", styleTestNoOp == styleOrig, true)

var badLenStyle = newSeq[float32](100)
var badLenStyleOrig = badLenStyle
applyEmotionVector(badLenStyle, "test_fixture_a", 1.0, table)
check("bad style length leaves untouched", badLenStyle == badLenStyleOrig, true)


if failures == 0:
  echo "\nALL TESTS PASSED"
  quit(0)
else:
  echo "\n", failures, " TEST(S) FAILED"
  quit(1)
