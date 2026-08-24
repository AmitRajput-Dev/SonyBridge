# XM4 v1 conformance coverage

The target contract is the Sony MDR v1 community specification at the revisions pinned in `PROVENANCE.md`. “MUST” here means required for SonyBridge's supported XM4 feature set, not a claim about Sony's unpublished full protocol.

| Section | MUST | SHOULD | Tested | Passing | Divergent | Score |
|---|---:|---:|---:|---:|---:|---:|
| Framing, escaping, length, checksum, round-trip | 8 | 0 | 8 | 8 | 0 | 100% |
| Safe protocol routing and inquiry payloads | 9 | 0 | 9 | 9 | 0 | 100% |
| Ambient/NC mode and levels 1/20 | 4 | 0 | 4 | 4 | 0 | 100% |
| EQ preset and persistent custom EQ | 3 | 0 | 3 | 3 | 0 | 100% |
| DSEE and Speak-to-Chat mutations | 2 | 0 | 2 | 2 | 0 | 100% |
| Malformed-frame rejection | 5 | 0 | 5 | 5 | 0 | 100% |

Hardware behavior is deliberately excluded from this file's score. It has a separate live-device verification gate because the public specification is reverse-engineered and Sony firmware can differ.
