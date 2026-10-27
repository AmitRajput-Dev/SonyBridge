# WH-1000XM4 macOS Roadmap

## Product direction

Turn SonyBridge into a dependable, native macOS companion for the WH-1000XM4. The first milestone favors safe device control and honest capability detection over broad model claims. Firmware installation is intentionally out of scope.

## Safety boundary

Sony's first- and second-generation control protocols reuse some opcode values for different operations. In particular, `0x22` requests battery state on v2 devices but powers off a v1 device such as the WH-1000XM4. Every request and mutation must therefore be selected from the connected transport's confirmed protocol version. Unsupported features stay hidden until their read-only inquiry succeeds.

## Milestones

### 1. First-class XM4 protocol support

- Initialize v1 devices before capability inquiries.
- Read battery, firmware, codec, equalizer, DSEE, Speak-to-Chat, and auto-power-off state with v1-specific commands.
- Normalize v1 and v2 equalizer values into one internal model.
- Parse v1 ANC and ambient responses so physical-button changes update the interface.
- Gate mutations behind successful read-only capability probes.
- Add regression coverage proving the XM4 path never emits the v2 battery opcode.

### 2. Headset verification

- Verify connection and initial state against a WH-1000XM4 on firmware 3.0.1.
- Exercise one control at a time and capture sanitized protocol diagnostics.
- Confirm state persists and remains synchronized after physical-button changes, reconnects, and idle link drops.

### 3. Native Mac experience

- Add a menu-bar surface for battery, ANC, Ambient Sound, and Speak-to-Chat.
- Keep the existing window for EQ and less-frequent settings.
- Add launch-at-login, automatic reconnect, clear loading states, and recoverable errors.
- Improve keyboard access, VoiceOver labels, contrast, and reduced-motion behavior.

### 4. Distribution quality

- Add unit tests for framing, protocol routing, parsing, and capability gating.
- Add CI for Apple Silicon and Intel builds.
- Rename the bundle identifier for the fork and document upstream attribution.
- Produce signed/notarized releases only when a dedicated identity is available.

## Definition of done for the first milestone

The app builds cleanly, connects to the paired XM4 without powering it off, displays the settings returned by the headset, exposes only verified controls, and safely handles disconnects and unanswered inquiries.
