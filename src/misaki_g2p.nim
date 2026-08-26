import std/[tables, strutils, re, strformat, sequtils, math]
import ./espeak, ./phonemize

# Misaki dict loader
var misakiDict*: Table[string, string]

proc initMisakiDict*(path: string) =
  if misakiDict.len > 0: return
  let f = open(path, fmRead)
  defer: f.close()
  var line = ""
  while f.readLine(line):
    let parts = line.split('\t', 1)
    if parts.len == 2:
      misakiDict[parts[0]] = parts[1]

# Espeak fallback E2M (from misaki.espeak.EspeakFallback.E2M)
const E2M = [
  ("ʔˌn\u0329", "ʔn"),
  ("ʔn\u0329", "ʔn"),
  ("a^ɪ", "I"),
  ("a^ʊ", "W"),
  ("d^ʒ", "ʤ"),
  ("e^ɪ", "A"),
  ("e", "A"),
  ("t^ʃ", "ʧ"),
  ("ɔ^ɪ", "Y"),
  ("ə^l", "ᵊl"),
  ("ʲo", "jo"),
  ("ʲə", "jə"),
  ("ʲ", ""),
  ("ɚ", "əɹ"),
  ("r", "ɹ"),
  ("x", "k"),
  ("ç", "k"),
  ("ɐ", "ə"),
  ("ɬ", "l"),
  ("\u0303", "")
]

proc applyE2M(ps: string): string =
  var res = ps
  for (oldVal, newVal) in E2M:
    res = res.replace(oldVal, newVal)
  res = res.replace(re("(\\S)\u0329"), "ᵊ$1")
  res = res.replace("\u0329", "")
  # US mappings
  res = res.replace("o^ʊ", "O")
  res = res.replace("ɜːɹ", "ɜɹ")
  res = res.replace("ɜː", "ɜɹ")
  res = res.replace("ɪə", "iə")
  res = res.replace("ː", "")
  res = res.replace("o", "ɔ")
  res = res.replace("ɾ", "T").replace("ʔ", "t")
  res = res.replace("^", "")
  res = res.replace(re("_+"), "_").replace("_", "")
  return res

proc espeakFallback*(e: var LibEspeak, word: string): string =
  var text = word
  let raw = e.rawPhonemes(text)
  var ps = raw.strip()
  if ps.len == 0: return ""
  return applyE2M(ps)

# Misaki subtokenize regex
let subtokenRegex = re("^['‘’]+|\\p{Lu}(?=\\p{Lu}\\p{Ll})|(?:^-)?(?:\\d?[,.]?\\d)+|[-_]+|['‘’]{2,}|\\p{L}*?(?:['‘’]\\p{L})*?\\p{Ll}(?=\\p{Lu})|\\p{L}+(?:['‘’]\\p{L})*|[^-_\\p{L}'‘’\\d]|['‘’]+$")

proc subtokenize(word: string): seq[string] =
  var m = 0
  while m < word.len:
    let b = word.findBounds(subtokenRegex, m)
    if b.first >= 0:
      result.add(word[b.first..b.last])
      m = b.last + 1
    else:
      break
  if result.len == 0: result.add(word)

let punctTagPhonemes = {"-LRB-": "(", "-RRB-": ")", "``": "“", "\"\"": "”", "''": "”"}.toTable
let puncts = [";", "…", "!", "—", ":", "?", ",", ".", "“", "”", "\"", "-", "_", "’", "'", "‘", "/", "(", ")"]

proc resolveWord*(e: var LibEspeak, word: string): string =
  # Very simplified resolution matching misaki.en.G2P.retokenize & lexicon
  if misakiDict.hasKey(word):
    return misakiDict[word]
  elif misakiDict.hasKey(word.toLowerAscii()):
    return misakiDict[word.toLowerAscii()]
  elif misakiDict.hasKey(word.capitalizeAscii()):
    return misakiDict[word.capitalizeAscii()]
  
  if word.len == 1 and $word[0] in puncts:
    return word

  # number processing fallback: just use espeak which misaki does anyway if num2words is absent
  # wait, misaki does subtokenize. Let's subtokenize and resolve each part
  let tokens = subtokenize(word)
  if tokens.len > 1:
    var phonemes = ""
    for tk in tokens:
      phonemes &= resolveWord(e, tk)
    return phonemes

  return espeakFallback(e, word)

proc misakiG2p*(e: var LibEspeak, text: string, lang="en-us", dictPath="src/misaki_dict.txt"): string =
  initMisakiDict(dictPath)
  if not e.voiceSet: e.setVoice(lang)

  # hide punctuation / split like phonemize.nim does? Misaki does its own split
  # But we can reuse phonemize.nim's preserveLine/chunks to split words keeping spaces
  var allChunks: seq[string]
  # var allMarks: seq[PunctMark] # Wait, phonemize.nim does not export PunctMark
  # Let's write a simple whitespace-preserving tokenizer
  
  let lines = text.split('\n')
  var res = ""
  for line in lines:
    var i = 0
    while i < line.len:
      if line[i] in {' ', '\t', '\r'}:
        res.add(line[i])
        inc i
      else:
        var w = ""
        while i < line.len and line[i] notin {' ', '\t', '\r'}:
          w.add(line[i])
          inc i
        let tokens = subtokenize(w)
        for t in tokens:
          let ps = resolveWord(e, t)
          if ps.len > 0:
            res.add(ps)
          else:
            res.add("❓")
  return res
