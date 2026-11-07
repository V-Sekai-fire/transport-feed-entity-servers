# iouring-feed-server-lean

Lean 4 port of the Rust `rust-iouring-kensac` submission (MIT, @kensac) to the arjaythedev
twelve-dollar-server-challenge. Original source is kept in `reference/`.

Scope: everything is ported to Lean except SQLite (the pinned amalgamation, bound over FFI) and
any FoundationDB layer (the submission has none; storage sits behind the abstract `App.Store`).

Status (layer by layer):
- Http: ported, `parse_done_le` and `headers_pos_le` proved
- Json reader/writer: ported, fixture-tested
- Sha256/HMAC/base64url/Jwt: ported, RFC vectors pass
- App routing/handlers: ported against abstract Store, `response_size`/`response_body` proved
- Not yet: Db FFI binding to SQLite shim, io_uring event loop (needs Linux + a thin C syscall glue)
