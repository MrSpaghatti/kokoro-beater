## phonemize.nim — faithful port of phonemizer.EspeakBackend phonemization
## (the exact chain kokoro-onnx uses):
##   1. punctuation is "hidden" (chunks) with mark positions B/E/I/A per line;
##   2. each chunk is phonemized independently through libespeak-ng;
##   3. marks are restored against the chunk list (mark.index = source line
##      number, exactly like phonemizer's _MarkIndex with `num`); the final
##      line group keeps word separators (strip=False -> trailing spaces).
## The output must match python `phonemizer.phonemize(text, "en-us",
## preserve_punctuation=True, with_stress=True)` so the vocab token ids are
## identical.

import std/[strutils, re]
import ./espeak

const PunctMarks = ";:,.!?¡¿—…\"" & "«»“”(){}[]"

type
  PunctMark = object
    mark: string     # the raw matched text, spaces included
    index: int       # source LINE number (python _MarkIndex.index)
    position: char   # 'B' 'E' 'I' 'A'

proc punctClass(): string =
  result = "["
  for c in PunctMarks:
    if c in {'[', ']', '\\', '^', '-', '"'}:
      result.add('\\')
    result.add c
  result.add(']')

let punctRun = re(r"(\s*" & punctClass() & r"+\s*)+")

# --- step 1: hide punctuation ----------------------------------------------

proc collectMatches(line: string): seq[tuple[first, last: int]] =
  var m = 0
  while m <= line.len:
    let b = line.findBounds(punctRun, m)
    if b.first < 0: break
    result.add b
    m = b.last + 1

proc preserveLine(line: string, lineNo: int): tuple[chunks: seq[string], marks: seq[PunctMark]] =
  let matches = collectMatches(line)
  if matches.len == 0:
    return (@[line], @[])
  var rest = line
  for i, b in matches:
    let markText = line[b.first .. b.last]
    var position = 'I'
    if b == matches[0] and line.startsWith(markText): position = 'B'
    elif b == matches[^1] and line.endsWith(markText): position = 'E'
    if matches.len == 1 and matches[0].first == 0 and matches[0].last == line.len - 1:
      position = 'A'     # a line that is only punctuation
    result.marks.add PunctMark(mark: markText, index: lineNo, position: position)
    let p = rest.find(markText)
    if p >= 0:
      result.chunks.add rest[0 ..< p]
      rest = rest[p + markText.len .. ^1]
    else:
      result.chunks.add ""
  if rest.len > 0:
    result.chunks.add rest
  # drop empties like preserve()'s `if line` filter
  var kept: seq[string]
  for c in result.chunks:
    if c.len > 0: kept.add c
  result.chunks = kept

# --- step 2: phonemize chunks ----------------------------------------------

proc chunkPhonemes(e: var LibEspeak, chunk: string): string =
  ## per chunk: espeak raw -> postprocess; a non-empty result keeps the
  ## trailing word separator (python _postprocess_line with strip=False).
  if chunk.strip().len == 0: return ""
  var pp = postprocess(e.rawPhonemes(chunk))
  if pp.len > 0: pp.add ' '
  result = pp

# --- step 3: restore marks --------------------------------------------------

proc restoreMarks(phon: seq[string], marks: seq[PunctMark]): seq[string] =
  ## Port of Punctuation.restore(.., sep.word=' ', strip=False).
  const sepWord = " "
  var text = phon
  var ms = marks
  var done: seq[string]
  var pos = 0
  while text.len > 0 or ms.len > 0:
    if ms.len == 0:
      for t in text: done.add t
      text.setLen(0)
    elif text.len == 0:
      var t = ""
      while ms.len > 0:
        t.add ms[0].mark
        ms.delete(0)
      done.add t
    else:
      let mk = ms[0]
      if mk.index == pos:
        var mstr = mk.mark.replace(" ", sepWord)
        if text[0].endsWith(sepWord):
          text[0] = text[0][0 ..< text[0].len - sepWord.len]
        case mk.position
        of 'B':
          text[0] = mstr & text[0]
        of 'E':
          done.add text[0] & mstr & (if mstr.endsWith(sepWord): "" else: sepWord)
          text.delete(0)
          inc pos
        of 'A':
          done.add mstr & (if mstr.endsWith(sepWord): "" else: sepWord)
          inc pos
        else:  # 'I'
          if text.len == 1:
            text[0] = text[0] & mstr
          else:
            let firstWord = text[0]
            text.delete(0)
            text[0] = firstWord & mstr & text[0]
        ms.delete(0)
      else:
        done.add text[0]
        text.delete(0)
        inc pos
  result = done

# --- public ------------------------------------------------------------------

proc phonemize*(e: var LibEspeak, text: string, lang = "en-us"): string =
  ## Full phonemizer-equivalent: text -> phoneme string (stress marks,
  ## punctuation, spaces) that the kokoro tokenizer then filters.
  if not e.voiceSet: e.setVoice(lang)

  var allChunks: seq[string]
  var allMarks: seq[PunctMark]
  let lines = text.split('\n')
  for i, line in lines:
    let (chunks, marks) = preserveLine(line, i)
    for c in chunks: allChunks.add c
    for mk in marks: allMarks.add mk

  var phon: seq[string]
  for c in allChunks:
    phon.add chunkPhonemes(e, c)

  result = restoreMarks(phon, allMarks).join("\n")