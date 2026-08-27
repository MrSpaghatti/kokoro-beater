## vocab.nim — the token vocabulary for Kokoro v1.0 (transcribed from
## kokoro_onnx config.json) plus the tokenizer + phoneme batch splitter that
## the python lib applies. Token ids are consumed straight by the ONNX model.

import std/[tables, unicode]

const MaxPhonemeLength* = 510

const VocabPairs = [
  (";", 1), (":", 2), (",", 3), (".", 4), ("!", 5), ("?", 6), ("—", 9),
  ("…", 10), ("\"", 11), ("(", 12), (")", 13), ("“", 14), ("”", 15), (" ", 16),
  ("\u0303", 17), ("ʣ", 18), ("ʥ", 19), ("ʦ", 20), ("ʨ", 21), ("ᵝ", 22),
  ("\uAB67", 23), ("A", 24), ("I", 25), ("O", 31), ("Q", 33), ("S", 35),
  ("T", 36), ("W", 39), ("Y", 41), ("ᵊ", 42), ("a", 43), ("b", 44), ("c", 45),
  ("d", 46), ("e", 47), ("f", 48), ("h", 50), ("i", 51), ("j", 52), ("k", 53),
  ("l", 54), ("m", 55), ("n", 56), ("o", 57), ("p", 58), ("q", 59), ("r", 60),
  ("s", 61), ("t", 62), ("u", 63), ("v", 64), ("w", 65), ("x", 66), ("y", 67),
  ("z", 68), ("ɑ", 69), ("ɐ", 70), ("ɒ", 71), ("æ", 72), ("β", 75), ("ɔ", 76),
  ("ɕ", 77), ("ç", 78), ("ɖ", 80), ("ð", 81), ("ʤ", 82), ("ə", 83), ("ɚ", 85),
  ("ɛ", 86), ("ɜ", 87), ("ɟ", 90), ("ɡ", 92), ("ɥ", 99), ("ɨ", 101),
  ("ɪ", 102), ("ʝ", 103), ("ɯ", 110), ("ɰ", 111), ("ŋ", 112), ("ɳ", 113),
  ("ɲ", 114), ("ɴ", 115), ("ø", 116), ("ɸ", 118), ("θ", 119), ("œ", 120),
  ("ɹ", 123), ("ɾ", 125), ("ɻ", 126), ("ʁ", 128), ("ɽ", 129), ("ʂ", 130),
  ("ʃ", 131), ("ʈ", 132), ("ʧ", 133), ("ʊ", 135), ("ʋ", 136), ("ʌ", 138),
  ("ɣ", 139), ("ɤ", 140), ("χ", 142), ("ʎ", 143), ("ʒ", 147), ("ʔ", 148),
  ("ˈ", 156), ("ˌ", 157), ("ː", 158), ("ʰ", 162), ("ʲ", 164), ("↓", 169),
  ("→", 171), ("↗", 172), ("↘", 173), ("ᵻ", 177),
]

type Vocab* = object
  table: Table[string, int16]

proc newVocab*(): Vocab =
  for (ch, id) in VocabPairs:
    result.table[ch] = int16(id)

proc tokenize*(v: Vocab, phonemes: string): seq[int64] =
  ## map phoneme runes -> ids; drop anything not in the vocab (same as
  ## `[i for i in map(self.vocab.get, phonemes) if i is not None]`).
  for r in phonemes.runes:
    let id = v.table.getOrDefault($r, int16(-1))
    if id >= 0:
      result.add int64(id)

proc splitPhonemes*(phonemes: string): seq[string] =
  ## Port of Kokoro._split_phonemes: split on `.,!?;` keeping the delimiters,
  ## accumulate into batches capped at 510 phoneme chars.
  ##
  ## Hard cap: a part that ALONE exceeds MaxPhonemeLength (e.g. a long run of
  ## unpunctuated text — "fox fox fox ...") is subdivided at spaces before
  ## batching, so no batch ever exceeds 510 chars. The python reference
  ## instead truncates silently in _create_audio (phonemes[:510]), dropping
  ## the tail; we split instead so no text is lost.
  var parts: seq[string]
  var cur = newStringOfCap(64)
  for ch in phonemes:
    if ch in ".,!?;":
      parts.add cur
      parts.add $ch
      cur.setLen(0)
    else:
      cur.add ch
  if cur.len > 0: parts.add cur

  var batches: seq[string]
  var current = ""
  for part in parts:
    let p = part.strip()
    if p.len == 0: continue
    if p.len >= MaxPhonemeLength:
      # oversized unpunctuated run: flush current, subdivide p on spaces
      if current.strip().len > 0:
        batches.add current.strip()
        current = ""
      var sub = newStringOfCap(64)
      for w in p.splitWhitespace:
        if w.len == 0: continue
        if sub.len + w.len + 1 >= MaxPhonemeLength:
          if sub.strip().len > 0:
            batches.add sub.strip()
          sub = w
        else:
          if sub.len > 0: sub.add ' '
          sub.add w
      if sub.strip().len > 0:
        batches.add sub.strip()
      continue
    if current.len + p.len + 1 >= MaxPhonemeLength:
      if current.strip().len > 0: batches.add current.strip()
      current = p
    else:
      if p.len == 1 and p[0] in ".,!?;":
        current.add p
      else:
        if current.len > 0: current.add ' '
        current.add p
  if current.strip().len > 0:
    batches.add current.strip()
  result = batches