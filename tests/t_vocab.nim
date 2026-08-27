## tests/t_vocab.nim — pure-Nim tests for phoneme batching invariants.
## Run: nim c -r --path:src tests/t_vocab.nim

import std/[strutils, sequtils]
import vocab

var failures = 0

proc check(label: string, pass: bool) =
  if pass:
    echo "PASS  ", label
  else:
    echo "FAIL  ", label
    inc failures

# invariant: no batch may exceed MaxPhonemeLength chars
let long = ("fox ").repeat(600).strip  # 1800 phoneme chars, unpunctuated
let longBatches = splitPhonemes(long)
check("unpunctuated 1800-char run splits into multiple batches", longBatches.len > 1)
var allLongOk = true
for b in longBatches:
  if b.len > MaxPhonemeLength: allLongOk = false
check "every unpunctuated batch <= MaxPhonemeLength", allLongOk
check "unpunctuated run text is preserved (no truncation)",
  longBatches.join(" ") == long

# original phoneme content intact after split/join for punctuated text
let punc = "wˈʌn tˈuː θɹˈiː. fˈɔːɹ fˈaɪv sˈɪks, sˈɛvən."
let puncBatches = splitPhonemes(punc)
check "short punctuated text yields one batch", puncBatches.len == 1
check "short punctuated text content preserved",
  puncBatches[0] == punc
var allPuncOk = true
for b in puncBatches:
  if b.len > MaxPhonemeLength: allPuncOk = false
check "every punctuated batch <= MaxPhonemeLength", allPuncOk
var puncEnds = 0
for b in puncBatches:
  if b[^1] in ".,!?;": inc puncEnds
check "punctuation retained at batch ends", puncEnds >= 1

# long punctuated text also stays within the cap
let longPunc = ("wˈʌn tˈuː θɹˈiː. ").repeat(60)
let longPuncBatches = splitPhonemes(longPunc)
var allLongPuncOk = true
for b in longPuncBatches:
  if b.len > MaxPhonemeLength: allLongPuncOk = false
check "long punctuated text: every batch <= MaxPhonemeLength", allLongPuncOk
check "long punctuated text: multiple batches", longPuncBatches.len > 1
check "long punctuated text preserved",
  longPuncBatches.join(" ") == longPunc.strip

# exact-size boundary: 509 chars + punct splits at the cap (python parity)
let exact = ("a").repeat(509) & "."
let exactBatches = splitPhonemes(exact)
check "exactly-MaxPhonemeLength content stays within cap",
  exactBatches.allIt(it.len <= MaxPhonemeLength)
check "exactly-MaxPhonemeLength content preserved",
  exactBatches.join("") == exact

# short input behaves like before (single batch, no crash)
check "short phrase is a single batch", splitPhonemes("hello world").len == 1

if failures == 0:
  echo "\nALL TESTS PASSED"
  quit(0)
else:
  echo "\n", failures, " TEST(S) FAILED"
  quit(1)