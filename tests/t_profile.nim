## tests/t_profile.nim — pure-Nim unit tests for profile formatting and RSS.
##
## Run: nim c -r --path:src tests/t_profile.nim

import std/[json, strutils]
import kbcli

var failures = 0

proc check(label: string, pass: bool) =
  if pass:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    inc failures

proc checkEq(label: string, got, want: string) =
  if got == want:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    echo "      got:  ", got
    echo "      want: ", want
    inc failures

# (a) peakRssKb returns a positive int (or at least non-negative, practically should be > 0 when running)
let rss = peakRssKb()
check("peakRssKb is non-negative", rss >= 0)
if rss == 0:
  echo "WARNING: peakRssKb returned 0, might be unsupported on this OS in getrusage."
else:
  check("peakRssKb > 0", rss > 0)

# (b) profile JSON builder test
let j = buildProfileJson(
  "af_bella", "model.onnx", 
  100, 50, 10, 20, 
  1.2345, 
  300, 1500, 0.15, 24000, 
  8192, 
  50, 1200, 150, 100
)

checkEq("json peak_rss_kb", $j["peak_rss_kb"].getInt(), "8192")
check("json has profile object", j.hasKey("profile") and j["profile"].kind == JObject)

let p = j["profile"]
check("profile has exactly 4 keys", p.len == 4)
checkEq("profile g2p_ms", $p["g2p_ms"].getInt(), "50")
checkEq("profile synth_ms", $p["synth_ms"].getInt(), "1200")
checkEq("profile trim_ms", $p["trim_ms"].getInt(), "150")
checkEq("profile write_ms", $p["write_ms"].getInt(), "100")

# (c) bench report formatting test
let report = formatBenchReport(
  230, 15.5, 340, 0.1234, 16384, 
  45, 1200, 130, 95
)

let wantReport = "bench: text_chars=230 audio_seconds=15.50 startup_ms=340 rtf=0.1234 peak_rss_kb=16384\nbench: g2p_ms=45 synth_ms=1200 trim_ms=130 write_ms=95"
checkEq("bench report matches exactly", report, wantReport)

if failures == 0:
  echo "\nALL TESTS PASSED"
  quit(0)
else:
  echo "\n", failures, " TEST(S) FAILED"
  quit(1)
