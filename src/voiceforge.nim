import std/[strutils, strformat, tables, math]
import ./npz

proc forgeVoice*(expr: string, voicesNpz: Npz): seq[float32] =
  # Expression is something like "0.5*af_bella+0.5*am_onyx" or just "af_bella"
  # Format: "weight1*name1+weight2*name2..."
  var parts: seq[tuple[weight: float, name: string]]
  
  if '+' notin expr and '*' notin expr:
    # Single voice — return the raw entry bytes untouched so a plain
    # `--voice af_bella` remains BIT-IDENTICAL to the pre-forge slice.
    for i, entry in voicesNpz.entries:
      if entry.name == expr:
        return entry.data
    raise newException(ValueError, "Voice not found in NPZ: " & expr)
  else:
    for p in expr.split('+'):
      let s = p.strip()
      if s.len == 0: continue
      if '*' in s:
        let pcs = s.split('*')
        if pcs.len == 2:
          parts.add((parseFloat(pcs[0].strip()), pcs[1].strip()))
        else:
          raise newException(ValueError, "Invalid voice expression segment: " & s)
      else:
        parts.add((1.0, s.strip()))

  # Validate names and normalize weights
  var totalWeight = 0.0
  for p in parts:
    totalWeight += p.weight
  
  if totalWeight == 0.0:
    raise newException(ValueError, "Total weight cannot be zero")

  if abs(totalWeight - 1.0) > 1e-5:
    for i in 0 ..< parts.len:
      parts[i].weight = parts[i].weight / totalWeight

  # Gather data arrays
  var nameToIdx = initTable[string, int]()
  for i, entry in voicesNpz.entries:
    nameToIdx[entry.name] = i

  var arrays: seq[seq[float32]]
  for p in parts:
    if not nameToIdx.hasKey(p.name):
      raise newException(ValueError, "Voice not found in NPZ: " & p.name)
    let idx = nameToIdx[p.name]
    arrays.add(voicesNpz.entries[idx].data)

  if arrays.len == 0:
    raise newException(ValueError, "No voices specified")

  let size = arrays[0].len
  result = newSeq[float32](size)
  
  for i in 0 ..< size:
    var sum = 0.0f32
    for j, p in parts:
      sum += arrays[j][i] * float32(p.weight)
    result[i] = sum
