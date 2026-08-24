# Protocol fuzzing

`FuzzCommandSerializer.cpp` targets the raw frame body accepted by
`CommandSerializer::unpackBtMessage`. It checks two properties:

- malformed input is rejected without memory errors or undefined behavior;
- valid packets retain their type, sequence, and payload after a package/decode
  round trip.

The corpus is generated in a temporary directory from reviewed hexadecimal seeds.
It includes empty, minimal valid, typical XM4, escaped-byte, truncated escape, and
oversized-length inputs. `sony_protocol.dict` supplies framing bytes and safe XM4
v1 inquiry opcodes.

Run the sanitizer campaign on macOS:

```sh
Client/fuzz/run-macos.sh
```

Override the default 60-second smoke duration with `FUZZ_SECONDS`. Crash artifacts
are intentionally kept outside the repository; minimize and reproduce any finding,
then add the smallest input to the permanent protocol regression tests.

MemorySanitizer is not included because it requires a fully instrumented C++
standard library. ThreadSanitizer is not applicable to this single-threaded parser
target; connection concurrency is covered by the protocol integration tests and
Xcode static analysis.
