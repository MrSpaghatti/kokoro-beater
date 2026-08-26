## npz.nim — minimal reader for numpy .npz containers (zip of .npy payloads).
## Covers exactly what kokoro's voices-v1.0.bin needs: STORED or DEFLATE
## entries, float32 little-endian, C order. Walks the zip central directory
## by hand, no zip library; DEFLATE uses dlopen'd libz.

import std/[os, strutils, dynlib]

type
  NpzEntry* = object
    name*: string
    data*: seq[float32]

  Npz* = object
    entries*: seq[NpzEntry]

# z_stream layout (zlib public struct, 64-bit ordering)
type ZStream = object
  nextIn: ptr uint8
  availIn: cuint
  totalIn: culong
  nextOut: ptr uint8
  availOut: cuint
  totalOut: culong
  msg: cstring
  state: pointer
  zalloc: pointer
  zfree: pointer
  opaque: pointer
  dataType: cint
  adler: culong
  reserved: culong

proc u16(b: string, off: int): int =
  int(b[off]) or (int(b[off+1]) shl 8)

proc u32(b: string, off: int): int =
  int(b[off]) or (int(b[off+1]) shl 8) or (int(b[off+2]) shl 16) or (int(b[off+3]) shl 24)

proc findEocd(b: string): int =
  for i in countdown(b.len - 22, 0):
    if b[i] == 'P' and b[i+1] == 'K' and b[i+2] == '\x05' and b[i+3] == '\x06':
      return i
  result = -1

proc startsWith(b: string, off: int, sig: string): bool =
  if off + sig.len > b.len: return false
  for i in 0 ..< sig.len:
    if b[off+i] != sig[i]: return false
  true

proc inflateRaw(src: string, expected: int): string =
  let z = loadLib("libz.so.1")
  if z == nil:
    raise newException(ValueError, "npz: deflated entry but libz.so.1 unavailable")
  let init2 = cast[proc(strm: pointer, windowBits: cint, ver: cstring, size: cint): cint {.cdecl.}](z.symAddr("inflateInit2_"))
  let infl = cast[proc(strm: pointer, flush: cint): cint {.cdecl.}](z.symAddr("inflate"))
  let endf = cast[proc(strm: pointer): cint {.cdecl.}](z.symAddr("inflateEnd"))
  if init2.isNil or infl.isNil or endf.isNil:
    raise newException(ValueError, "npz: libz missing inflate symbols")

  var strm: ZStream
  if init2(addr strm, -15'i32, "1.2.3".cstring, int32(sizeof(ZStream))) != 0:
    raise newException(ValueError, "npz: inflateInit2_ failed")
  var outBuf = newString(expected)
  strm.nextIn = cast[ptr uint8](unsafeAddr src[0])
  strm.availIn = cuint(src.len)
  strm.nextOut = cast[ptr uint8](unsafeAddr outBuf[0])
  strm.availOut = cuint(expected)
  let rc = infl(addr strm, 4'i32)      # Z_FINISH
  discard endf(addr strm)
  if rc notin [0, 1]:                   # Z_OK, Z_STREAM_END
    raise newException(ValueError, "npz: inflate failed rc=" & $rc)
  result = outBuf

proc npyToFloats(data: string, expectedCount: int): seq[float32] =
  ## One .npy payload: 6-byte magic, 2-byte header length, ascii dict, then
  ## raw little-endian float32 samples.
  if data.len < 10 or data[0] != '\x93' or data[1] != 'N' or data[2] != 'U':
    raise newException(ValueError, "npz: bad npy magic")
  let hdrLen = u16(data, 8)
  let bodyOff = 10 + hdrLen
  if data.len < bodyOff or (data.len - bodyOff) mod 4 != 0:
    raise newException(ValueError, "npz: corrupt npy body")
  let n = (data.len - bodyOff) div 4
  if expectedCount > 0 and n != expectedCount:
    raise newException(ValueError, "npz: entry has " & $n & " floats, expected " & $expectedCount)
  let hdr = data[10 ..< bodyOff]
  if "f4" notin hdr:
    raise newException(ValueError, "npz: entry is not float32")
  if "fortran_order" in hdr and "fortran_order': True" in hdr:
    raise newException(ValueError, "npz: fortran-order array unsupported")
  result = newSeq[float32](n)
  if n > 0:
    copyMem(addr result[0], unsafeAddr data[bodyOff], n * 4)

type CdInfo = object
  name: string
  compMethod: int
  compSize, uncompSize: int
  localOff: int

proc readNpz*(path: string, perEntryFloats: int = -1): Npz =
  ## perEntryFloats > 0: enforce each npy payload's float count (512*510).
  let b = readFile(path)
  let eocd = findEocd(b)
  if eocd < 0: raise newException(ValueError, "npz: not a zip (no EOCD)")
  let totalEntries = u16(b, eocd + 10)
  var cdOff = u32(b, eocd + 16)

  var dirs: seq[CdInfo]
  for i in 0 ..< totalEntries:
    if not startsWith(b, cdOff, "PK\x01\x02"):
      raise newException(ValueError, "npz: bad central directory entry")
    let compMethod = u16(b, cdOff + 10)
    let compSize = u32(b, cdOff + 20)
    let uncompSize = u32(b, cdOff + 24)
    let nameLen = u16(b, cdOff + 28)
    let extraLen = u16(b, cdOff + 30)
    let commentLen = u16(b, cdOff + 32)
    let localOff = u32(b, cdOff + 42)
    dirs.add CdInfo(name: b[cdOff+46 ..< cdOff+46+nameLen], compMethod: compMethod,
                    compSize: compSize, uncompSize: uncompSize, localOff: localOff)
    cdOff += 46 + nameLen + extraLen + commentLen

  for d in dirs:
    if not startsWith(b, d.localOff, "PK\x03\x04"):
      raise newException(ValueError, "npz: bad local header for " & d.name)
    let lNameLen = u16(b, d.localOff + 26)
    let lExtraLen = u16(b, d.localOff + 28)
    let dataOff = d.localOff + 30 + lNameLen + lExtraLen
    var payload: string
    if d.compMethod == 0:               # STORED
      payload = b[dataOff ..< dataOff + d.compSize]
    elif d.compMethod == 8:             # DEFLATE
      payload = inflateRaw(b[dataOff ..< dataOff + d.compSize], d.uncompSize)
    else:
      raise newException(ValueError, "npz: unsupported method " & $d.compMethod)
    var entryName = d.name
    if entryName.endsWith(".npy"):
      entryName = entryName[0 .. ^5]
    result.entries.add NpzEntry(name: entryName, data: npyToFloats(payload, perEntryFloats))