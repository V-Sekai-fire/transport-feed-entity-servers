# transport-iouring-feed-server

Lean 4 port of the Rust `rust-iouring-kensac` submission (MIT, @kensac) to the arjaythedev
twelve-dollar-server-challenge. The original source is kept in `datasources/reference/`.

SQLite is not rewritten: the unmodified 3.54.1 amalgamation and the original B-tree shim
(`datasources/csrc/shim.c`, one portability guard for `SYS_gettid`) are bound over a thin Lean-ABI glue
(`datasources/csrc/lean_glue.c`). The submission has no FoundationDB code. A `fdb:<name>` path opens the store's FoundationDB VFS
(`datasources/store`); CI checks open, write and reopen against a live cluster, and the parity figures
below were measured on SQLite only.

`entity-server` is a sibling of `feed-server`: a 64 Hz UDP tick (skateboard slice, plain syscalls only; the io_uring send path was removed), with the 100-byte packet layout from `datasources/entity-packet`. See RFD66606-2442 and RFD66606-2443.

## Layers
- `Http`: request parser. Proved: a parsed request never claims more bytes than the buffer holds.
- `Json`: validating reader, unescape, escape. Fixture-tested.
- `Sha256`, `Jwt`: HMAC-SHA256, base64url, HS256 verification. RFC vectors pass.
- `Record`: SQLite varint and record decoding. Proved: reads stay in bounds, column sizes match their serial types.
- `Db`: feed, post, likes and inserts over an abstract `Cursors` record. Tested on an in-memory fake and on a real SQLite file.
- `App`: routing and handlers. Proved: Content-Length always matches the body. A write sets `wrote`, and `endBatch` commits.
- `Conn`: per-connection serve and batch policy. Proved: a rolled-back batch closes the connection and drops its answers.
- `Server` + `transports/csrc/ring_glue.c`: io_uring event loop (Linux only).

## Verification
- `lake exe feed-tests`: 62 checks (Mac and Linux).
- `deploy/scripts/smoke.sh`: curl smoke test.
- `deploy/scripts/accept.sh`: the challenge's own `test/test.sh` (42/42) against the Lean server, in a privileged Ubuntu 24.04 container (`deploy/Containerfile`).

## Differences from the Rust original (not tuned)
- One ring with single-shot accept/recv/send: no multishot, provided-buffer rings or spill rings.
- Each SQLite payload is copied once into a `ByteArray`.
- Held writes are retried each pass.
- Not load-tested, so no throughput claim.

## Build
```
bash deploy/scripts/fetch-sqlite.sh      # pinned SQLite amalgamation, sha256-checked
lake build feed-tests && lake exe feed-tests
podman build -t feed-lean -f deploy/Containerfile .
podman run --rm --privileged -v "$PWD":/src:ro feed-lean bash /src/deploy/scripts/accept.sh
```
