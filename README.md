# iouring-feed-server-lean

Lean 4 port of the Rust `rust-iouring-kensac` submission (MIT, @kensac) to the arjaythedev
twelve-dollar-server-challenge. The original source is kept in `reference/`.

SQLite is not rewritten: the unmodified 3.54.1 amalgamation and the original B-tree shim
(`csrc/shim.c`, one portability guard for `SYS_gettid`) are bound over a thin Lean-ABI glue
(`csrc/lean_glue.c`). The submission has no FoundationDB code. Storage sits behind
`App.Store`, so an FDB backend could plug in there.

## Layers
- `Http`: request parser. Proved: a parsed request never claims more bytes than the buffer holds.
- `Json`: validating reader, unescape, escape. Fixture-tested.
- `Sha256`, `Jwt`: HMAC-SHA256, base64url, HS256 verification. RFC vectors pass.
- `Record`: SQLite varint and record decoding. Proved: reads stay in bounds, column sizes match their serial types.
- `Db`: feed, post, likes and inserts over an abstract `Cursors` record. Tested on an in-memory fake and on a real SQLite file.
- `App`: routing and handlers. Proved: Content-Length always matches the body. A write sets `wrote`, and `endBatch` commits.
- `Conn`: per-connection serve and batch policy. Proved: a rolled-back batch closes the connection and drops its answers.
- `Server` + `csrc/ring_glue.c`: io_uring event loop (Linux only).

## Verification
- `lake exe feed-tests`: 62 checks (Mac and Linux).
- `scripts/smoke.sh`: curl smoke test.
- `scripts/accept.sh`: the challenge's own `test/test.sh` (42/42) against the Lean server, in a privileged Ubuntu 24.04 container (`Containerfile`).

## Differences from the Rust original (not tuned)
- One ring with single-shot accept/recv/send: no multishot, provided-buffer rings or spill rings.
- Each SQLite payload is copied once into a `ByteArray`.
- Held writes are retried each pass.
- Not load-tested, so no throughput claim.
