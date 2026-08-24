# Fixture provenance

The XM4 v1 payloads are cross-checked against two independently maintained community references:

- Gadgetbridge `27ed00aa4232eaa360172b78b35d2fb168c190f0`: `PayloadTypeV1.java` and `SonyProtocolImplV1.java`. This is the primary source for command IDs, subtypes, and payload layouts, including DSEE, auto power-off, EQ, ambient sound, battery, firmware, codec, and Speak-to-Chat.
- `tanat/sony-connect-osx` `1a68e3bee54778c2db92db6379fa24662537b1db`: `SonyPacket.swift` and `HeadphonesController.swift`. This is an XM4-specific independent source for frame escaping, checksum rules, strict frame length, and the core XM4 commands.

The exact frames were generated on 2026-08-24 with Ruby 3.4 from `generate_reference_goldens.rb`. That script is a clean-room transcription of the documented wire rules and pinned payload facts. Regenerate to a temporary file, diff every byte against `fixtures/xm4_v1_frames.golden`, and update this file when either reference revision changes.

The fixture is deterministic and platform-independent. It uses exact byte comparison; no scrubbing or tolerance is appropriate.
