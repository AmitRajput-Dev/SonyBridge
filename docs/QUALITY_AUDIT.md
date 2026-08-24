# Quality audit

This log records the four-pass hardening work performed for first-class WH-1000XM4 support.

## Pass 1: surface scan

- Baseline protocol tests and a strict C++20 build passed.
- Xcode's static analyzer completed without findings. UBS was not available on this machine.
- Fixed RFCOMM shutdown calling `disconnect()` from the connector thread, which could join itself.
- Fixed failed and remotely closed connections leaving a joinable thread that could terminate the app.
- Made connector shutdown idempotent and wake blocked readers immediately.
- Fixed frame parsing so transport noise before a start marker is ignored and oversized frames are rejected.

## Pass 2: fresh-eyes review

- Replaced queued raw `Headphones*` captures with retained `shared_ptr` values to prevent use-after-free on disconnect.
- Serialized status reads, dynamic polling, and writes on one device-I/O queue.
- Locked headphone property reads and bounded ambient/EQ values stored in the model.
- Fixed v2 devices remaining permanently “changed” because v1-only VPT state was included.
- Capability-gated optional setters in the C++ core, not only in the UI.
- Fixed interleaved headset notifications being mistaken for command acknowledgments.
- Tightened frame decoding to reject trailing bytes after the checksum.

## Pass 3: integration

- Added regression coverage for preamble noise and notification-before-ACK ordering.
- Protocol tests pass with `-Wall -Wextra -Werror`.
- The macOS Debug app builds successfully after the lifecycle and concurrency changes.
- `git diff --check` passes.

## Pass 4: verification

- Xcode static analysis passes after all fixes.
- The strict protocol suite passes after the final rescan.
- No deferred bug-hunt findings remain. Protocol conformance, fuzzing, security, hardware, UX, and release checks are tracked as separate ordered passes.
