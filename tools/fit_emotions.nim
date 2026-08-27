import std/[json, strutils, math, tables, os]

proc round6(val: float32): float32 =
  round(val * 1e6) / 1e6

proc main() =
  let path = "tests/fixtures/voices_prosody.json"
  let content = readFile(path)
  let j = parseJson(content)
  
  var voices: seq[seq[float32]]
  
  for key, val in j.pairs:
    var vec: seq[float32]
    for item in val:
      vec.add(item.getFloat().float32)
    voices.add(vec)
    
  let N = voices.len
  let D = 128
  
  # Compute mean
  var mean = newSeq[float32](D)
  for i in 0 ..< N:
    for j in 0 ..< D:
      mean[j] += voices[i][j]
  for j in 0 ..< D:
    mean[j] /= float32(N)
    
  # Center
  var centered = newSeq[seq[float32]](N)
  for i in 0 ..< N:
    centered[i] = newSeq[float32](D)
    for j in 0 ..< D:
      centered[i][j] = voices[i][j] - mean[j]
      
  # Covariance
  var cov = newSeq[seq[float32]](D)
  for i in 0 ..< D:
    cov[i] = newSeq[float32](D)
    
  for i in 0 ..< D:
    for j in 0 ..< D:
      var sum: float32 = 0
      for k in 0 ..< N:
        sum += centered[k][i] * centered[k][j]
      cov[i][j] = sum / float32(N - 1)
      
  # Power iteration for top 5 PC
  var eigenvecs = newSeq[seq[float32]](5)
  var eigenvals = newSeq[float32](5)
  
  var covCopy = cov
  for pc in 0 ..< 5:
    var vec = newSeq[float32](D)
    # init random (or simple deterministic)
    for i in 0 ..< D:
      vec[i] = if (i mod 2) == 0: 1.0'f32 else: -1.0'f32
      
    var norm: float32 = 0
    for i in 0 ..< D: norm += vec[i]*vec[i]
    norm = sqrt(norm)
    for i in 0 ..< D: vec[i] /= norm
    
    var val: float32 = 0
    for iter in 0 ..< 100:
      var newVec = newSeq[float32](D)
      for i in 0 ..< D:
        var sum: float32 = 0
        for j in 0 ..< D:
          sum += covCopy[i][j] * vec[j]
        newVec[i] = sum
        
      var newNorm: float32 = 0
      for i in 0 ..< D: newNorm += newVec[i]*newVec[i]
      newNorm = sqrt(newNorm)
      
      val = newNorm
      for i in 0 ..< D: vec[i] = newVec[i] / newNorm
      
    eigenvecs[pc] = vec
    eigenvals[pc] = val
    
    # deflate
    for i in 0 ..< D:
      for j in 0 ..< D:
        covCopy[i][j] -= val * vec[i] * vec[j]
        
  echo "--- PCA Fitting Summary ---"
  echo "Number of voices: ", N
  echo "Dimensionality: ", D
  
  var meanStr = "Mean vector sample (first 5): "
  for i in 0..<5: meanStr.add($round(mean[i], 4) & " ")
  echo meanStr
  
  echo "Top 5 Eigenvalues (energy explained):"
  for pc in 0 ..< 5:
    echo "  PC", pc+1, ": ", round(eigenvals[pc], 6)
    
  # Map emotions to PCA directions
  # PC1 seems to carry the most variance. We assign it to cheerful (+)/sad (-).
  # PC2 assigned to angry (+)/calm (-).
  # PC3 assigned to whisper (+).
  var emotionVecs = initTable[string, seq[float32]]()
  
  # Scale to roughly max abs 0.15 for audible but non-clipping effect
  let targetMax = 0.15'f32
  
  # Helper to scale vector
  proc getScaled(vec: seq[float32], sign: float32): seq[float32] =
    result = newSeq[float32](D)
    var maxAbs = 0.0'f32
    for i in 0 ..< D:
      let v = abs(vec[i])
      if v > maxAbs: maxAbs = v
      
    let scale = targetMax / maxAbs
    for i in 0 ..< D:
      result[i] = round6(vec[i] * sign * scale)
      
  emotionVecs["cheerful"] = getScaled(eigenvecs[0], 1.0)
  emotionVecs["sad"]      = getScaled(eigenvecs[0], -1.0)
  emotionVecs["angry"]    = getScaled(eigenvecs[1], 1.0)
  emotionVecs["calm"]     = getScaled(eigenvecs[1], -1.0)
  emotionVecs["whisper"]  = getScaled(eigenvecs[2], 1.0)
  
  echo "\nEmotion Vector Summaries:"
  for k, v in emotionVecs.pairs:
    var l2: float32 = 0
    var mabs: float32 = 0
    for x in v:
      l2 += x*x
      if abs(x) > mabs: mabs = abs(x)
    l2 = sqrt(l2)
    echo "  ", k, ": L2 norm = ", round(l2, 4), ", max abs = ", round(mabs, 4)
    
  echo "\nPairwise Dot Products (Orthogonality Check):"
  let keys = ["cheerful", "sad", "angry", "calm", "whisper"]
  for i in 0 ..< keys.len:
    for j in i+1 ..< keys.len:
      var dot: float32 = 0
      for k in 0 ..< D:
        dot += emotionVecs[keys[i]][k] * emotionVecs[keys[j]][k]
      echo "  ", keys[i], " · ", keys[j], " = ", round(dot, 6)
      
  # Write JSON
  let outPath = "src/emotions.json"
  var outObj = newJObject()
  for k in keys:
    var arr = newJArray()
    for val in emotionVecs[k]:
      arr.add(newJFloat(val))
    outObj[k] = arr
    
  # Pretty print to maintain exact shape 
  # Actually, the requirement asks for "5 keys, each 128 floats, values rounded to 6 decimal places"
  # I will write a custom formatter to ensure no scientific notation and matching formatting.
  var jsonStr = "{\n"
  for i, k in keys:
    jsonStr &= "  \"" & k & "\": [\n"
    for j in 0 ..< D:
      let val = emotionVecs[k][j]
      var s = formatFloat(val, ffDecimal, 6)
      if not s.contains("."): s &= ".0"
      jsonStr &= "    " & s
      if j < D - 1: jsonStr &= ",\n"
      else: jsonStr &= "\n"
    jsonStr &= "  ]"
    if i < keys.len - 1: jsonStr &= ",\n"
    else: jsonStr &= "\n"
  jsonStr &= "}\n"
  
  writeFile(outPath, jsonStr)
  echo "\nWrote ", outPath

main()