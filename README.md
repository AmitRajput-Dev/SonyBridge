<div align="center">

# 🎧 SonyBridge

### Control your Sony headphones from your desktop — the way the mobile app won't let you.

A modern, native **macOS** app (with cross-platform roots) to control Sony headphones over Bluetooth:
**Noise Cancelling**, **Ambient Sound**, **Equalizer**, and **Battery** — including newer models
like the **WH-CH720N** and **WH-1000XM4/XM5** that speak Sony's second-generation protocol.

<br/>

![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-blue)
![UI](https://img.shields.io/badge/macOS%20UI-SwiftUI-orange)
![Language](https://img.shields.io/badge/core-C%2B%2B20-00599C)
![License](https://img.shields.io/badge/license-MIT-green)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

<br/>

<img src="docs/connected.png" width="360" alt="SonyBridge connected to WH-CH720N">

</div>

---

## Why

Sony locks headphone settings behind their mobile-only *Sound Connect* app. If you live on a laptop,
you're stuck. SonyBridge talks to the headphones directly over Bluetooth RFCOMM using Sony's
reverse-engineered binary protocol — no phone required.

The original [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient) only spoke Sony's
**first-generation** protocol, so newer headsets (WH-CH720N, XM4/XM5, WF-series, LinkBuds…) just timed
out on connect. SonyBridge adds full **second-generation ("v2") protocol** support and a clean SwiftUI
interface built for those devices.

## ✨ Features

- 🎚️ **Ambient Sound Control** — Noise Cancelling · Ambient Sound (0–20 levels) · Off
- 🗣️ **Focus on Voice** passthrough
- 🎛️ **Equalizer** — read the active preset and switch between Off, Bright, Excited, Mellow, Relaxed, Vocal, Treble, Bass & Speech
- 🔋 **Battery level** — live percentage, right in the header
- 🔌 **Auto-connect** — finds your already-paired Sony headset, no fiddly device picker
- 🌑 **Native SwiftUI** — dark, minimal, and shaped after Sony's own app
- 🧩 **Dual-protocol** — automatically detects and speaks either protocol generation

<div align="center">
<img src="docs/disconnected.png" width="300" alt="Disconnected state">
</div>

## 🎧 Supported headphones

| Status | Devices |
|--------|---------|
| ✅ **Verified** | WH-CH720N |
| 🟢 **Expected** (v2, over-ear, single battery) | WH-1000XM4, WH-1000XM5, WH-XB910N, WH-CH520 |
| 🟡 **Partial** (v2 earbuds — controls work, battery format differs) | WF-1000XM4, WF-1000XM5, WF-C700N, LinkBuds S |
| 🔵 **Legacy** (original v1 protocol) | WH-1000XM3, WH-1000XM2, WH-XB900N, MDR-XB950BT |

> Only the WH-CH720N is hardware-verified. Other models share the same protocol family, so the basics
> should work — but per-model quirks are untested. Reports and PRs for other devices are very welcome.

## 🚀 Build & run

### macOS (recommended — native SwiftUI app)

Requires **Xcode 14+**.

```sh
git clone --recurse-submodules https://github.com/AmitRajput-Dev/SonyBridge.git
open SonyBridge/Client/macos/SonyHeadphonesClient.xcodeproj
```

Then ⌘R. On first launch, grant Bluetooth permission. **Connect your headphones in macOS Bluetooth
settings first**, then hit *Connect headphones* in the app.

> 💡 Keep audio playing while you use the app — Sony headsets drop the Bluetooth control link when idle
> to save power.

### Windows / Linux (Dear ImGui UI, inherited from upstream)

<details>
<summary>Build instructions</summary>

**Windows** (CMake + MSVC, from a Developer Command Prompt):
```sh
cd Client && mkdir build && cd build
cmake .. && cmake --build .
```

**Linux** (`sudo apt install libbluetooth-dev libglew-dev libglfw3-dev libdbus-1-dev`):
```sh
cd Client && mkdir build && cd build
cmake .. && cmake --build .
```

The macOS SwiftUI interface is macOS-only; Windows/Linux use the original Dear ImGui GUI.
</details>

## 🔬 How it works

Sony headphones expose a vendor RFCOMM/SPP service. Commands are framed as:

```
<START 0x3e> ESCAPE( <TYPE> <SEQ> <4-byte BE length> <PAYLOAD> <checksum> ) <END 0x3c>
```

Two protocol generations exist, distinguished by their SDP service UUID:

- **v1** — `96CC203E-…` — WH-1000XM3 and older
- **v2** — `956C7B26-…` — WH-CH720N, XM4/XM5, WF-series, LinkBuds…

SonyBridge tries v1 first, falls back to v2, and remembers which succeeded. The v2 path adds the
mandatory init handshake and per-frame host-ACK the newer devices require, plus battery and equalizer
inquiry/response commands.

Protocol details were reverse-engineered by the community. Battery and EQ byte layouts in particular were
cross-referenced against [**GadgetBridge**](https://codeberg.org/Freeyourgadget/Gadgetbridge)'s excellent
Sony implementation.

## 🙏 Credits

SonyBridge builds directly on the work of:

- [**SonyHeadphonesClient**](https://github.com/Plutoberth/SonyHeadphonesClient) by Plutoberth, Mr-M33533K5, and contributors — the original cross-platform client and protocol foundation
- [**semvis123**](https://github.com/semvis123) — the original macOS port
- [**GadgetBridge**](https://codeberg.org/Freeyourgadget/Gadgetbridge) — reverse-engineered v2 protocol reference (battery, EQ)

## ⚠️ Disclaimer

This project is **not affiliated with, endorsed by, or connected to Sony**. It talks to your headphones
using a reverse-engineered protocol, for interoperability. Use at your own risk.

## 📄 License

[MIT](LICENSE) — see the LICENSE file. Original copyright retained; see [Credits](#-credits).
