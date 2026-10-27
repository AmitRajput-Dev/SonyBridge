# Multipoint ("Connect to 2 devices simultaneously") — protocol research

Research date: 2026-08-24. Question: can SonyBridge toggle Sony's multipoint setting without
the phone app, using only wire bytes proven by an existing implementation?

## Sources examined

- **Gadgetbridge** (codeberg.org/Freeyourgadget/Gadgetbridge, `master`), path
  `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/{devices,service/devices}/sony/headphones/`.
  Files pulled raw and cross-checked against the repository's commit API (the GitHub mirror is the
  archived 2022 snapshot and predates this feature).
- **Plutoberth/SonyHeadphonesClient** (upstream of this codebase): issues #113 ("Change pairing
  mode sony headphone") and #114 ("Feature request: switch bluetooth source") are open feature
  requests with no frames and no implementation. No prior multipoint art exists there.

## Finding 1 — v1 (WH-1000XM4): NOT implemented anywhere. No proven frames exist.

`SonyProtocolImplV1.java` (protocol/impl/v1) implements the capability interface with an explicit
negative — both methods log and return null:

```java
public Request setConnectTwoDevices(final ConnectTwoDevices config) {
    LOG.warn("Connect two devices not implemented for V1");
    return null;
}
public Request getConnectTwoDevices() {
    LOG.warn("Connect two devices not implemented for V1");
    return null;
}
```

`PayloadTypeV1.java` contains no multipoint/pairing-management payload type. No v1 device
coordinator declares `SonyHeadphonesCapabilities.ConnectTwoDevices`.

**Consequence for SonyBridge: the XM4 gets no multipoint support.** Inventing v1 frames to send
at real hardware is out of scope by policy; this repo only ships wire bytes a proven
implementation has sent at a real device. The v1 test suite instead asserts the XM4 path never
emits any of the v2 multipoint opcodes (`d6`/`d8`/`98`).

## Finding 2 — v2: proven by Gadgetbridge on the WH-ULT900N (ULT WEAR)

Added 2026-07-08 by David Giron, three commits (in order):

1. `8cbc309346` "WIP add ConnectTwoDevices feature" — first cut: GET `96 00 06`,
   SET `98 00 06 <01|00>` (SYSTEM_CONTROL family, subcode 0x06).
2. `e8520865f3` "fix: setting Connect Two Devices" — hardware testing showed the SET value byte is
   ignored; the state is actually driven through the touch-sensor `d1` subtype, and `98 00 06 01`
   is a fixed "apply" commit sent after it for **both** directions.
3. `5d7b37d1b7` "fix read Connect Two Devices" — hardware testing showed `SYSTEM_CONTROL_RET`
   (`97 00 06 xx`) always reports `01` regardless of actual state, so the GET was changed to the
   touch-sensor read, whose RET carries the real value.

Final proven wire contract (`SonyProtocolImplV2.java` `setConnectTwoDevices`/`getConnectTwoDevices`/
`setWideAreaTap`/`handleTouchSensor`, `SonyHeadphonesProtocol.java` `PREF_SONY_CONNECT_TWO_DEVICES`
case; only `SonyWHULT900NCoordinator` declares the capability):

| Step | Payload | Meaning |
|---|---|---|
| GET | `d6 d1` | read state |
| RET | `d7 d1 00 XX` | `XX == 00` → multipoint ON, `01` → OFF (enable bit inverted) |
| SET (1st frame) | `d8 d1 00 XX` | `00` → ON, `01` → OFF |
| SET (2nd frame) | `98 00 06 01` | fixed apply commit, identical bytes for ON and OFF |

Frame order for SET: the `d8 d1 ...` state frame is sent first (it is the returned
`configRequest`, encoded immediately); the `98 00 06 01` commit is queued and drained on the next
ACK. SonyBridge reproduces this with two sequential `sendCommand` calls, each of which waits for
its ACK.

### Caveat carried into the implementation

On devices with real touch-tap hardware (LinkBuds family), touch-sensor subtype `d1` is Wide Area
Tap, not multipoint; Gadgetbridge distinguishes by per-model capability lists. SonyBridge gates by
capability probe instead (house style): the toggle appears only when the device answers `d6 d1`,
and the byte contract is only hardware-proven for the WH-ULT900N family. This is noted at the
probe site in `Headphones.cpp`.

## What SonyBridge implements

- v2 only: probe `d6 d1` appended to `probeCapabilities()` (v2 branch), state parsed per the table
  above; `setMultipoint()` sends `d8 d1 00 XX` then `98 00 06 01`.
- v1 (XM4): nothing — `hasMultipoint()` stays false, `setMultipoint()` throws.
- Offline proof: `HeadphonesProtocolTests.cpp` (FakeV2Connector GET/RET exchange + exact SET frame
  bytes; v1 negative assertions) and `conformance/fixtures/ult900n_v2_multipoint.golden`
  (exact framing for all six payloads).
