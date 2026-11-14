# Spans from the entity server

`transports/csrc/otel_span.h` is the span half of the engine's `open_telemetry` module in C99, and the
guest `interactor-otel-guest` is the same module for scripts. A hot loop records a finished span into a
fixed ring of 4,096 records, which costs one struct copy and no allocation. `otel_flush` writes one
OTLP protobuf record, and the server calls it only in the idle part of a tick, when the ring is half full and more than 3 ms remain.
A full ring drops the span and counts it.

## Where the spans go

The server records an `entity.run` span with a child `entity.tick` for every tick, in every run, and appends
them to a file as protobuf records. The attributes of a tick are `clients`, `packets_in`, `datagrams_out` and
`tick`. There is no switch: `ENTITY_OTEL=<file>` names the file and defaults to `/dev/null`, which is a place,
so the work is the same whether anyone reads it. A file that cannot be opened stops the run with an error.

A record is a 4-byte little-endian length and one `ScopeSpans` message. The resource, which may hold a key, is
left out on purpose, so no key is written to disk.

## What the collector wants

AppSignal's collector takes OTLP over HTTP as protobuf and reads its push key from the resource attribute
`appsignal.config.push_api_key`, not from a header. `tools/otlp_post_pb.exs` of `interactor-otel-guest` wraps
each record in a `ResourceSpans` with a resource it builds from its own environment and posts it as
`application/x-protobuf` to the collector's `/v1/traces`.

## Check

`transports/test/otel_span_witness.cpp` holds the properties, built on witness-cpp. Every property reads the
records back with an independent decoder: each field of every span matches what was recorded, span ids are never
zero and never repeat, and a full ring drops and counts. A planted-false property must be caught. Two more
builds plant a defect each, `-DOTEL_PLANT_PBTIMES` (the end time written as the start) and
`-DOTEL_PLANT_PBPARENT` (the parent id left out); CTest runs them with `WILL_FAIL`.

    cmake -S transports/test -B build && cmake --build build && ctest --test-dir build
