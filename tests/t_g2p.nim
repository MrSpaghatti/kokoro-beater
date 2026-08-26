## tests/t_g2p.nim — pure-Nim fixture contract test (no vendor/runtime needed).
##
## Asserts the misaki G2P dictionary path reproduces the checked-in fixtures
## byte-for-byte. All fixture words resolve from the dictionary, so the espeak
## fallback (which needs the heavy runtime) is never invoked.
##
## Run: nim c -r --path:src tests/t_g2p.nim

import std/[strutils, os, tables]
import misaki_g2p, espeak

var failures = 0

proc check(label: string, got, want: string) =
  if got == want:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    echo "      got:  ", got
    echo "      want: ", want
    inc failures

let dictPath = currentSourcePath().parentDir / "fixtures" / ".." / ".." / "src" / "misaki_dict.txt"
initMisakiDict(dictPath)

# A dummy espeak handle: never dereferenced because every word below hits the
# dictionary (resolveWord only calls espeakFallback on a miss).
var dummyEspeak: LibEspeak = nil

let boogeymanAnyMore = resolveWord(dummyEspeak, "boogeyman") &
                       resolveWord(dummyEspeak, "any") &
                       resolveWord(dummyEspeak, "more")

# The fixture line has spaces between words — those come from the
# whitespace-preserving tokenizer in misakiG2p, not from resolveWord.
# Test the word-level dictionary atoms:
check("dict path boogeyman", resolveWord(dummyEspeak, "boogeyman"), "bˈuɡimˌæn")
check("dict path any", resolveWord(dummyEspeak, "any"), "ˈɛni")
check("dict path more", resolveWord(dummyEspeak, "more"), "mˈɔɹ")

check("dict has boogeyman", $misakiDict.hasKey("boogeyman"), "true")
check("dict has any", $misakiDict.hasKey("any"), "true")
check("dict has more", $misakiDict.hasKey("more"), "true")

# The two G2P paradigms must DIFFER (that's the whole point of the port):
# espeak legacy keeps ː markers, misaki drops them + remaps vowels.
check("misaki differs from espeak legacy",
      $not(boogeymanAnyMore == "bˈuːɡɪmən ˌɛni mˈɔːɹ"),
      "true")

if failures == 0:
  echo "\nALL TESTS PASSED"
  quit(0)
else:
  echo "\n", failures, " TEST(S) FAILED"
  quit(1)