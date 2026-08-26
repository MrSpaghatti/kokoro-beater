## tests/t_espeak.nim — isolate the espeak phonemize step.
import std/[os, strutils, dynlib, posix]
import ../src/espeak

proc dbg(msg: string) =
  discard write(2, msg.cstring, msg.len)

let exeDir = getAppDir().parentDir   # tests/ -> project root
var e = loadEspeak(defaultEspeakLibrary(exeDir))
e.init(defaultEspeakData(exeDir))
dbg("loaded+init\n")
dbg("voice rc: " & $(e.espeakSetVoiceByName("en-us")) & "\n")

var pstr = "hi there"
var pptr = cstring(pstr)
var phandle = cast[ptr ptr cchar](addr pptr)

var iters = 0
var total = ""
while true:
  let chunk = e.espeakTextToPhonemes(phandle, 1'i32, 0x5F02'i32)
  if iters < 6:
    dbg("iter " & $iters & " chunk=" & $(if chunk == nil: "<nil>" else: $chunk) & "\n")
  if chunk == nil: break
  total.add($chunk)
  inc iters
  if iters > 100:
    dbg("LOOP LIMIT HIT — pointer not advancing\n")
    break

dbg("iters=" & $iters & " total=" & total & "\n")