# Adversarial static audit — inbound Bluetooth frame parser

Scope traced: `CommandSerializer.cpp/.h`, `ByteMagic.cpp/.h`, `Headphones.cpp/.h`,
`BluetoothWrapper.cpp/.h` (framing layer feeding the parser), `Constants.h`, `Exceptions.h`.
Trust boundary: raw bytes an attacker-controlled/spoofed headset writes on the RFCOMM channel.

## Bottom line

I could not find a memory-safety bug, integer-overflow bug, escape-handling bug, or
round-trip divergence on the inbound path. The frame (de)serializer and the framing layer
are unusually careful. Below are (a) the specific defenses I verified by tracing concrete
byte sequences, and (b) three low/informational observations that are NOT exploitable as
written but are worth knowing. Nothing here is CONFIRMED-exploitable.

The fuzz harness (`FuzzCommandSerializer.cpp`) only drives `unpackBtMessage` /
`packageDataForBt`. It never reaches `BluetoothWrapper::_readMessage` (the marker/leftover
framing) or the `Headphones::request*` consumers — so I put most reading effort there.
Those paths are also clean; details below.

---

## Verified defenses (traced with concrete inputs)

### D1 — `unpackBtMessage` length math cannot underflow or over-read
`CommandSerializer.cpp:136-173`.
- `unescaped.size() < 7` is rejected first (line 142), so indices `[0..6]` used to read
  `dataType`, `seq`, the 4 size bytes, and the checksum byte always exist.
- `dataSize` is assembled as `unsigned int` from 4 bytes (max `0xFFFFFFFF`). Line 153
  `dataSize > unescaped.size() - 7`: `size` is `size_t >= 7`, so `size - 7` never wraps;
  the comparison promotes `dataSize` to `size_t`, so a huge declared size is rejected, not
  truncated.
- Line 157 forces `dataSize == size - 7` exactly (rejects trailing bytes). Consequently the
  checksum index `unescaped[6 + dataSize]` (line 163) is exactly `size - 1` — always the
  last valid byte — and the payload slice `[begin+6, begin+6+dataSize)` (line 171) ends
  exactly at `size - 1`. No off-by-one.
- Trigger bytes I checked: minimal empty-payload frame body (unescaped)
  `00 00 00 00 00 00 00` → dataSize 0, checksum at [6], payload empty: accepted, no OOB.
  Body `3E 3E 3E` (len 3 < 7) → clean throw. Declared-size overflow body
  `00 00 FF FF FF FF <n bytes> CK` → rejected at line 153.

### D2 — escape/unescape is symmetric and bounded
`_escapeSpecials` / `_unescapeSpecials` (`CommandSerializer.cpp:11-85`).
- A trailing lone sentry `0x3D` at end of buffer is explicitly rejected
  (`i == src.size() - 1` → throw, line 54) — no read past the end for the escaped byte.
- Sentry followed by any byte other than `44/45/46` throws ("Unexpected escaped byte") —
  an escape can never synthesize an out-of-range value; it only ever emits `60/61/62`.
- The three escapable values (`60/61/62`) and the sentry (`61`) are all `< 128`, so the
  `char`-vs-int `switch`/`==` comparisons are sign-safe (no negative-`char` mismatch).
- Delimiters `START=62` / `END=60` are themselves escaped inside the body, so a well-formed
  body never contains a raw delimiter; the framing layer strips markers before unescape.
- Trigger checked: `3D` (single byte) → throw, no over-read; `3D 44` → `60`; `3D 99` → throw.

### D3 — checksum is computed over identical bytes on both sides
`_sumChecksum` (`CommandSerializer.cpp:87-100`) accumulates into `unsigned char`. Pack sums
`[dataType..payload]` (pre-escape) and appends it; unpack sums `unescaped[0 .. 6+dataSize)`
= the same logical bytes. The signed-`char` element promotion is identical on both sides, so
`unpack(pack(x))` reproduces the same checksum. No signedness bypass, no round-trip drift.

### D4 — `_readMessage` framing cannot overrun `buf[2048]`
`BluetoothWrapper.cpp:109-182`.
- `recv(buf, sizeof(buf))` and the leftover replay both cap at `sizeof(buf)` via
  `std::min(_leftoverBytes.size(), sizeof(buf))` (line 123); `numRecvd <= 2048` always.
- `messageStart`/`messageEnd` stay within `[0, numRecvd]`; the only way `messageStart` is set
  is `i+1` on a START at index `i < numRecvd` (so `<= numRecvd`), and an END that sets
  `messageEnd = i` is only reached *after* a START in the same scan (`i` strictly greater),
  so the `insert(buf+messageStart, buf+messageEnd)` range is never inverted.
- `_leftoverBytes.assign(buf+i+1, buf+numRecvd)` uses `i+1 <= numRecvd` — valid, possibly
  empty.
- Total accumulation is bounded: `msgBytes.size() > MAX_BLUETOOTH_MESSAGE_SIZE` throws, so an
  attacker who never sends END cannot grow memory without bound (DoS-bounded).
- A second START while a message is ongoing → clean `RecoverableException(shouldDisconnect)`.

### D5 — no attacker-controlled value is ever used as an array index
Every payload-derived array access in `Headphones.cpp` uses a *fixed* loop bound, not a
payload value: `_eqBands[i]` and `resp[5+i]` (i in 0..4, guarded by `resp.size() >= 10`,
lines 186-192); `APO_CODES[index]` is only reached via `setAutoPowerOff`, which validates
`index` in 0..5 (line 440), and `apoIndexFromCode` returns a value found by a fixed 0..5 scan
(lines 359-366). Enum values decoded from the wire (`DATA_TYPE`, `EQ_PRESET`) are only ever
compared or displayed, never used to index a table → no enum-driven OOB.

### D6 — every consumer bounds-checks before indexing, and every call site catches
`std::exception`
Traced all `request*`/`probeCapabilities` readers: each guards with `resp.size()` before the
highest index it reads (`requestBattery` `<4`/`>=4`/`>=6`; `requestEqualizer` `>=3`/`>=10`;
`requestAmbientState` v2 `>=7`, v1 `==8`; `requestDsee` `>=3`/`>=4`; `probeCapabilities`
`>3`/`>=3`/`>=4`/`>=5`). `sendCommandAndReadResponse` only returns a payload after checking
`!payload.empty()` (so `payload[0]` is safe) and, for subtype matches, `payload.size() >= 2`.
Every invocation in `CrossPlatformGUI.cpp` and `macos/HeadphonesBridge.mm` is wrapped in
`catch (const std::exception&)` / `catch (const RecoverableException&)`, so the mix of thrown
types (see O1) cannot escape to terminate the process.

---

## Observations (low / informational — not exploitable as written)

### O1 — INFO — inconsistent exception type in the parser (not a vuln, verified caught)
`CommandSerializer.cpp:56, 74, 144` throw plain `std::runtime_error`, while the size/checksum
rejections at 155/159/165 throw `RecoverableException`. If any call site ever caught *only*
`RecoverableException`, a malformed frame (e.g. body `3D` → "No data left for escaped byte
data", or a `< 7`-byte body) would become an uncaught exception → `std::terminate` → remote
DoS. I checked every reachable call site (`CrossPlatformGUI.cpp:126/157/189-244/566-586`,
`HeadphonesBridge.mm:169-361`, `windows/main.cpp:18`, `linux/main.cpp:17`): all catch
`std::exception`, so today this is **safe**. Flagged only because the invariant is implicit —
a future call site that narrows to `RecoverableException` would silently turn any bad frame
into a crash. Recommend making the parser throw `RecoverableException` uniformly.
Status: SUSPECTED-DoS in theory, CONFIRMED-not-reachable in this tree.

### O2 — LOW — unvalidated device-reported scalar values (cosmetic, no memory impact)
Battery level (`Headphones.cpp:109/120/133/144`), EQ band values, DSEE/adaptive flags, etc.
are stored straight from the wire with no range validation (e.g. a spoofed headset can report
battery `0xFF` → "255%"). Purely a UI-correctness issue; no bounds or state-corruption
consequence. Worth a `clamp`/range check for polish, not a security fix.

### O3 — LOW — attacker-controlled firmware/codec strings rendered in UI
`probeCapabilities` builds `_firmware = std::string(r.begin()+3, r.end())`
(`Headphones.cpp:390/412`) from up to ~2041 attacker-chosen bytes, including NULs and control
bytes, and displays it. ImGui renders text literally (no escape-sequence interpretation), so
this is not a terminal-injection vector in the shipped GUI; it would only matter if the string
were ever echoed to a raw terminal/log. Informational.

---

## Out-of-scope-but-checked

`ByteMagic::MACBytesToString` reads a fixed 6 bytes and `MACStringToLong` parses a config
string; both are Windows-only and fed by OS device-enumeration / user config, not by inbound
frame bytes — outside this trust boundary and outside the macOS target. No issue on the
inbound path.

## Round-trip

`unpack(pack(x)) == x` holds for `(dataType, seqNumber, payload)`: pack writes
`static_cast<unsigned char>(dataType)`, the low byte of `seqNumber`, a 4-byte BE size, the
payload, and a checksum, then canonically escapes; unpack reverses each step and the exact
`dataSize == size-7` check rejects any non-canonical framing. I could not construct an
accepted frame that fails to re-pack-and-re-decode identically (oversized-after-escape frames
are rejected by `packageDataForBt`'s `MAX_BLUETOOTH_MESSAGE_SIZE` guard, which the harness
already treats as expected). No divergence found.
