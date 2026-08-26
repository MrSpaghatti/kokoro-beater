import std/[json, tables, strutils, math, os]

proc loadEmotions*(path: string): Table[string, seq[float32]] =
  if not fileExists(path):
    raise newException(IOError, "Emotion file not found: " & path)

  let content = readFile(path)
  var j: JsonNode
  try:
    j = parseJson(content)
  except JsonParsingError as e:
    raise newException(ValueError, "Failed to parse JSON in " & path & ": " & e.msg)

  if j.kind != JObject:
    raise newException(ValueError, "Expected JSON object at root of " & path)

  for name, node in j.pairs:
    if node.kind != JArray:
      raise newException(ValueError, "Expected JSON array for emotion '" & name & "'")
    if node.len != 128:
      raise newException(ValueError, "Expected exactly 128 prosody floats for emotion '" & name & "', found " & $node.len)

    var arr: seq[float32] = @[]
    for item in node:
      if item.kind notin {JFloat, JInt}:
        raise newException(ValueError, "Expected numbers in array for emotion '" & name & "'")
      let val = item.getFloat()
      if not val.classify.in {fcNormal, fcZero}:
        raise newException(ValueError, "Expected finite numbers for emotion '" & name & "'")
      arr.add(float32(val))
    
    result[name] = arr

proc applyEmotionVector*(style: var openArray[float32], emotion: string, offset: float, table: Table[string, seq[float32]]) =
  if emotion == "" or offset == 0.0 or style.len != 256:
    return

  if not table.hasKey(emotion):
    var available: seq[string] = @[]
    for k in table.keys:
      available.add(k)
    raise newException(ValueError, "Unknown emotion '" & emotion & "'. Available emotions: " & available.join(", "))

  let vec = table[emotion]
  let offsetF32 = float32(offset)
  
  for i in 128..255:
    style[i] += vec[i - 128] * offsetF32
